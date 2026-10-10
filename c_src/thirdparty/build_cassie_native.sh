#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
#
# Builds the vendored geogram (BSD-3) + PMP (MIT) subset CASSIE's
# triangulation/remeshing pipeline needs, plus the three Lean FFI
# wrapper TUs (cassie_geogram_ffi.cpp, cassie_pmp_ffi.cpp,
# cassie_obj_ffi.cpp), into one static archive:
#   c_src/thirdparty/build/libcassie_native.a
#
# The exact .cpp allow/deny lists mirror
# fabric-godot-core's modules/cassie/SCsub (ENG-88) exactly -- see that
# file's comments for why each exclusion exists (AGPL/non-commercial
# licensing for tetgen/triangle, unused Voronoi/CSG/IO/image code, or
# throw-heavy paths Godot's -fno-exceptions build had to avoid).
#
# Unlike the Godot module build, this is a standalone static library
# with no -fno-exceptions constraint, so none of the throw-to-abort
# patches Godot's build needed apply here -- normal C++ exceptions are
# left enabled, compiling the upstream sources unmodified.
#
# Usage: bash build_cassie_native.sh

set -euo pipefail
cd "$(dirname "$0")"

CXX=g++
GEOGRAM=geogram/geogram
PMP=pmp/pmp
BUILD=build
mkdir -p "$BUILD"

# Both libraries' own sources #include via their package-root-relative
# path (e.g. <geogram/basic/common.h>, <pmp/surface_mesh.h>) -- include
# the PARENT of each vendored tree, not the tree itself.
CXXFLAGS=(
  -std=c++17 -O2 -fPIC -c
  -DGEOGRAM_WITH_BUILTIN_DEPS -DGEOGRAM_USE_BUILTIN_DEPS
  -D_USE_MATH_DEFINES
  "-DGEOGRAM_VERSION=\"1.9.9\""
  -DPMP_SCALAR_TYPE_64=1
  -Wno-unknown-pragmas -Wno-deprecated-declarations
  -I geogram -I "$GEOGRAM/third_party" -I "$GEOGRAM/third_party/OpenNL"
  -I pmp -I eigen
)

CFLAGS=(
  -O2 -fPIC -c
  -DGEOGRAM_WITH_BUILTIN_DEPS -DGEOGRAM_USE_BUILTIN_DEPS
  -I geogram -I "$GEOGRAM/third_party" -I "$GEOGRAM/third_party/OpenNL"
)

LEAN_INC="c:/Users/ernes/.elan/toolchains/leanprover--lean4---v4.34.1/include"

# ---- geogram allow/deny lists (mirrors modules/cassie/SCsub) ----
# boolean_expression.cpp (CSG expression parser) is NOT skipped here,
# unlike upstream modules/cassie/SCsub -- CDT_2d.cpp's
# classify_triangles() actually calls into GEO::BooleanExpression, a
# real link-time dependency upstream's exclusion missed (that Godot
# module's native side was never actually link-tested end to end --
# see its own lakefile/README notes about unresolved FFI stubs).
basic_skip="geofile.cpp android_utils.cpp"
delaunay_skip="delaunay_2d.cpp delaunay_tetgen.cpp delaunay_triangle.cpp parallel_delaunay_3d.cpp"
mesh_keep="mesh.cpp mesh_reorder.cpp"
points_skip="co3ne.cpp"

skip_listed() {
  local base name
  base="$1"; shift
  for name in "$@"; do
    if [ "$base" = "$name" ]; then return 0; fi
  done
  return 1
}

geogram_objs=()
compile_one() {
  local src="$1"
  local obj="$BUILD/$(echo "$src" | tr '/' '__' | sed 's/\.cpp$/.o/;s/\.c$/.o/')"
  if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ]; then
    echo "  cc  $src" >&2
    "$CXX" "${CXXFLAGS[@]}" "$src" -o "$obj"
  fi
  echo "$obj"
}

for f in "$GEOGRAM"/basic/*.cpp; do
  base=$(basename "$f")
  skip_listed "$base" $basic_skip && continue
  geogram_objs+=("$(compile_one "$f")")
done

for f in "$GEOGRAM"/numerics/*.cpp; do
  geogram_objs+=("$(compile_one "$f")")
done

for base in $mesh_keep; do
  geogram_objs+=("$(compile_one "$GEOGRAM/mesh/$base")")
done

for f in "$GEOGRAM"/delaunay/*.cpp; do
  base=$(basename "$f")
  skip_listed "$base" $delaunay_skip && continue
  geogram_objs+=("$(compile_one "$f")")
done

for f in "$GEOGRAM"/points/*.cpp; do
  base=$(basename "$f")
  skip_listed "$base" $points_skip && continue
  geogram_objs+=("$(compile_one "$f")")
done

for f in "$GEOGRAM"/bibliography/*.cpp; do
  geogram_objs+=("$(compile_one "$f")")
done

CC=gcc
for f in "$GEOGRAM"/third_party/OpenNL/*.c; do
  obj="$BUILD/$(basename "$f" .c).o"
  if [ ! -f "$obj" ] || [ "$f" -nt "$obj" ]; then
    echo "  cc  $f" >&2
    "$CC" "${CFLAGS[@]}" "$f" -o "$obj"
  fi
  geogram_objs+=("$obj")
done

# ---- PMP allow list (mirrors modules/cassie/SCsub's pmp_keep_algos) ----
pmp_keep_algos="remeshing.cpp decimation.cpp differential_geometry.cpp normals.cpp features.cpp smoothing.cpp utilities.cpp distance_point_triangle.cpp triangulation.cpp curvature.cpp laplace.cpp numerics.cpp"

pmp_objs=()
for f in "$PMP"/*.cpp; do
  pmp_objs+=("$(compile_one "$f")")
done
for base in $pmp_keep_algos; do
  f="$PMP/algorithms/$base"
  if [ -f "$f" ]; then
    pmp_objs+=("$(compile_one "$f")")
  fi
done

# ---- Lean FFI wrapper TUs ----
ffi_objs=()
for f in ffi/cassie_geogram_ffi.cpp ffi/cassie_pmp_ffi.cpp ffi/cassie_obj_ffi.cpp; do
  obj="$BUILD/$(basename "$f" .cpp).o"
  if [ ! -f "$obj" ] || [ "$f" -nt "$obj" ]; then
    echo "  cc  $f" >&2
    "$CXX" -std=c++17 -O2 -fPIC -c -I "$LEAN_INC" -I geogram -I pmp -I eigen \
      -D_USE_MATH_DEFINES -DPMP_SCALAR_TYPE_64=1 -Wno-deprecated-declarations \
      "$f" -o "$obj"
  fi
  ffi_objs+=("$obj")
done

echo "ar  $BUILD/libcassie_native.a"
ar rcs "$BUILD/libcassie_native.a" "${geogram_objs[@]}" "${pmp_objs[@]}" "${ffi_objs[@]}"
echo "OK  $BUILD/libcassie_native.a"

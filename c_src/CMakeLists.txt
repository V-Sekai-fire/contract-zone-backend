# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
#
# The NIF shared library the Elixir GenServer loads. No engine/Godot
# build involved - libriscv::Machine is a pure host-side C++ library,
# fully testable on its own (same principle the weft-warp-loop session
# this was ported from already proved for the fabric-godot-core Sandbox
# port).
cmake_minimum_required(VERSION 3.20)
project(weft_warp_burrito_native CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# libriscv is linked into weft_sandbox_nif, a SHARED library - on ELF/Linux
# (unlike the PE/Windows DLLs this build was originally proved on) every
# object folded into a shared object must be position-independent, or the
# final link fails with "can not be used when making a shared object".
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(RISCV_32I OFF CACHE BOOL "" FORCE)
set(RISCV_64I ON CACHE BOOL "" FORCE)
set(RISCV_BINARY_TRANSLATION OFF CACHE BOOL "" FORCE)
add_subdirectory(thirdparty/libriscv/lib)
# The host-math ecall (RFD 0018) lives at 600, past godot-sandbox's
# 500-549 block; libriscv's default syscall table caps at 512. PUBLIC:
# the table size is baked into Machine's layout, so every consumer must
# agree.
target_compile_definitions(riscv PUBLIC RISCV_SYSCALLS_MAX=1024)
if(WIN32)
  target_compile_definitions(riscv PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

# The actual NIF the Elixir GenServer loads. ERTS_INCLUDE_DIR is passed
# in by c_src/Makefile (elixir_make's entry point) - not hardcoded,
# since it depends on the Erlang install on whatever machine builds
# this. No erl_interface/erts import-lib linkage is needed: on both
# Windows and Unix, a NIF is a plain shared library the BEAM loads via
# dlopen/LoadLibrary and resolves nif_init from by symbol name.
if(DEFINED ERTS_INCLUDE_DIR)
  add_library(weft_sandbox_nif SHARED nif/weft_sandbox_nif.cpp)
  target_include_directories(weft_sandbox_nif PRIVATE ${ERTS_INCLUDE_DIR} ${FINE_INCLUDE_DIR})
  target_link_libraries(weft_sandbox_nif PRIVATE riscv)
  set_target_properties(weft_sandbox_nif PROPERTIES PREFIX "")
  # The BEAM loads a NIF as .so on macOS too, and resolves enif_* from itself.
  if(APPLE)
    set_target_properties(weft_sandbox_nif PROPERTIES SUFFIX ".so")
    target_link_options(weft_sandbox_nif PRIVATE -undefined dynamic_lookup)
  endif()
  # Fine's own README: hides NIF symbols so this library doesn't clash
  # with other Fine-based NIFs loaded into the same BEAM node.
  if(NOT MSVC)
    target_compile_options(weft_sandbox_nif PRIVATE -fvisibility=hidden)
  endif()
endif()

# RFD 0043: standalone host-side verification that libriscv's RV64GC
# double-precision arithmetic matches native x86-64 execution bit-for-
# bit, given a guest ELF built by hand (see c_src/lockstep/README.md --
# not part of this CMake build, requires riscv-none-elf-gcc, which is
# deliberately NOT a dependency of the default `nif` build target after
# RFD 0039). Not part of the default build (mirrors this project's
# existing convention for standalone verification tools -- see
# verify_guest.cpp before its RFD 0039 retirement): build explicitly
# with `cmake --build build --target verify_float_determinism`.
add_executable(verify_float_determinism
  host_test/verify_float_determinism.cpp
  lockstep/vector3.c)
target_include_directories(verify_float_determinism PRIVATE lockstep)
target_link_libraries(verify_float_determinism PRIVATE riscv)

# RFD 0043's other two float-determinism strategies (RFD 0042):
# fixed-point ("ban floats"/"integer-only") and a minimal illustrative
# softfloat. Same manual-build convention as verify_float_determinism
# above -- build explicitly with
#   cmake --build build --target verify_alt_strategies
add_executable(verify_alt_strategies
  host_test/verify_alt_strategies.cpp
  lockstep/guest_alt.c)
target_include_directories(verify_alt_strategies PRIVATE lockstep)
target_link_libraries(verify_alt_strategies PRIVATE riscv)

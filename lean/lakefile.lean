-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 K. S. Ernest (iFire) Lee
import Lake
open System Lake DSL

package «lockstep» where

require «lean-capstone» from git
  "https://github.com/fire/lean-capstone" @ "main"

-- LeanSlang — the AST + emitter for Slang shader source, needed by
-- CassieAvbd's Cg/ubershader codegen and Cloth.SlangCodegen (ported in
-- alongside modules/cassie/lean/ below).
require LeanSlang from git
  "https://github.com/V-Sekai-fire/contract-lean-slang.git" @ "60532aef8ed70cc669ecab481182d0636c9e1ac3"

-- The AVBD cloth kernels and their property ladder live in interactor-drape.
require Cloth from git
  "https://github.com/V-Sekai-fire/interactor-drape" @ "6d707bb675b5710c545e850cfb3b4b3792a95bd8" / "lean"

-- LockstepDeterminism.lean (RFD 0043's spec) is intentionally NOT a
-- target of this package -- it has no dependencies of its own and
-- keeps working exactly as documented (`lean --run
-- lean/LockstepDeterminism.lean`), independent of this lakefile.

-- RFD 0043's follow-on: check_no_fma.lean, using this org's own
-- fire/lean-capstone (a Lean4 Capstone binding) instead of shelling out
-- to riscv-none-elf-objdump + scripts/check_no_fma.py's regex parsing --
-- reuses an owned asset and stays in the same Lean4 tooling this
-- pipeline already depends on end to end.
lean_exe check_no_fma where
  root := `CheckNoFma
  moreLinkArgs := #["-Wl,--start-group",
    ".lake/packages/lean-capstone/thirdparty/capstone/lib/libcapstone.a",
    "-Wl,--end-group"]

-- ════════════════════════════════════════════════════════════════════
-- CASSIE (fabric-godot-core#feat/module-cassie) -- Lean formal specs +
-- Slang shader codegen for the VR-sketching engine module, per RFD
-- 0020's own sequencing ("Cassie... enters later as one more input
-- source to the same loop"). CassieGeogram/CassiePmp/CassieObj's
-- native side (real geogram/PMP/Eigen, vendored at
-- c_src/thirdparty/{geogram,pmp,eigen}, plus the Lean FFI wrapper TUs
-- at c_src/thirdparty/ffi/) is built by
-- c_src/thirdparty/build_cassie_native.sh into
-- c_src/thirdparty/build/libcassie_native.a -- run that script before
-- `lake build` on a fresh checkout. A pure-Lean reimplementation of
-- the Delaunay/remeshing algorithms was tried first and dropped: it
-- couldn't match the real libraries' performance on this pipeline's
-- actual boundary sizes.
-- ════════════════════════════════════════════════════════════════════
def cassieNativeLib : String := "../c_src/thirdparty/build/libcassie_native.a"
def cassieNativeLinkArgs : Array String :=
  #["-Wl,--start-group", cassieNativeLib, "-Wl,--end-group", "-lstdc++"]


-- CASSIE-specific composition layer that imports Cloth.* and exports
-- the CASSIE-shaped theorem statements + codegen entry-point.
lean_lib «CassieAvbd» where
  roots := #[`CassieAvbd]

-- Surface mesh remeshing/smoothing -- FFI into real PMP, see
-- CassiePmp/Mesh.lean.
lean_lib «CassiePmp» where
  roots := #[`CassiePmp]

-- Constrained Delaunay triangulation -- FFI into real geogram, see
-- CassieGeogram/Delaunay.lean.
lean_lib «CassieGeogram» where
  roots := #[`CassieGeogram]

-- Wavefront OBJ loader -- FFI, see CassieObj.lean.
lean_lib «CassieObj» where
  roots := #[`CassieObj]

-- Polylines JSON loader (pure Lean.Data.Json) -- gives cycle_patch a
-- runtime path (`cycle_patch --input X.json`) so externally-produced
-- stroke sets don't need codegen + Lean recompile to drive the
-- forward pipeline.
lean_lib «CassiePolylinesJson» where
  roots := #[`CassiePolylinesJson]

-- DiffCloth's original shader-emit exe -- kept available because its
-- IO.FS.writeFile + slangc-invocation pattern is the reference the
-- CASSIE avbd-codegen mirrors.
lean_exe «emit_shaders» where
  root := `EmitShaders

-- Emits the AVBD solver kernels (Spmv / Saxpby / CG / Wahba, etc.)
-- from the composed Lean kernels: Lean source -> LeanSlang.Emit ->
-- Slang text -> slangc.
lean_exe «avbd-codegen» where
  root := `CassieAvbd.Codegen
  supportInterpreter := true

-- CycleDetect parameter sweep -- `lake exe cycle_sweep` runs the
-- arrangement build + cycle finder over a small (proximity, mergeEps)
-- grid against the hat fixture and prints exact-match counts.
lean_exe «cycle_sweep» where
  root := `CycleSweep
  supportInterpreter := true

-- Dumps HatRawData back to JSON for the roundtrip soundness check.
lean_exe «hat_dump» where
  root := `HatDump
  supportInterpreter := true

lean_exe «json_test» where
  root := `JsonTest
  supportInterpreter := true

lean_exe «json_float_test» where
  root := `JsonFloatTest
  supportInterpreter := true

lean_exe «stroke_diff» where
  root := `StrokeDiff
  supportInterpreter := true

-- Transport.lean smoke tests (Bezier eval / tangent / parallel
-- transport / crossNode).
lean_exe «transport_smoke» where
  root := `TransportSmoke
  supportInterpreter := true

-- NodeAugment.augment smoke test on hat polylines.
lean_exe «node_augment_smoke» where
  root := `NodeAugmentSmoke
  supportInterpreter := true

-- Compares legacy findCycles vs. the Unity-port findCyclesPort on the
-- hat polylines fixture.
lean_exe «walk_probe» where
  root := `WalkProbe
  supportInterpreter := true

-- 65-dataset arrangement parity probe -- runs buildArrangementAugmented
-- on a polylines JSON and prints {nodes, edges, sharp, strokes}.
lean_exe «arrangement_probe» where
  root := `ArrangementProbe
  supportInterpreter := true

-- Smoke test for the CassieObj FFI loader on any OBJ file.
lean_exe «obj_probe» where
  root := `ObjProbe
  supportInterpreter := true
  moreLinkArgs := cassieNativeLinkArgs

-- Cycle -> patch end-to-end. `lake exe cycle_patch` builds the hat
-- arrangement, picks the longest cycle, walks its boundary as a flat
-- polyline, runs geogram CDT2d, then PMP implicit smoothing. Closes
-- the detect -> triangulate -> fair loop with real input data.
lean_exe «cycle_patch» where
  root := `CyclePatch
  supportInterpreter := true
  moreLinkArgs := cassieNativeLinkArgs

-- Surface-fairing smoke test -- `lake exe surface_fair` builds a small
-- mesh in Lean, hands it to PMP via the CassiePmp FFI, runs implicit
-- smoothing, prints counts.
lean_exe «surface_fair» where
  root := `SurfaceFair
  supportInterpreter := true
  moreLinkArgs := cassieNativeLinkArgs

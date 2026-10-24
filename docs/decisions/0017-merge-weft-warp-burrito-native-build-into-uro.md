---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly to main, no PR review
labels: hrr, migration, repo-structure
---

# 0017 Merge weft_warp_burrito's native build into :uro, add RISC-V toolchain to CI

## Context

Following [[0016-merge-taskweft-nif-native-build-into-uro]], `WeftWarpBurrito.Sandbox`
(moved into `lib/` per [[0015-extract-taskweft-rebac-and-sandbox-into-lib]])
still referenced `WeftWarpBurrito.SandboxNif`, which stayed in the
`CI=true`-excluded `weft_warp_burrito` dependency — breaking `mix compile
--warnings-as-errors` in CI (`WeftWarpBurrito.SandboxNif is not available`).
Chose to fully merge rather than revert, accepting the CI cost of installing
a RISC-V cross-compiler.

## Decision Outcome

Moved `WeftWarpBurrito.SandboxNif` into `lib/weft_warp_burrito/sandbox_nif.ex`
(`:code.priv_dir(:weft_warp_burrito)` → `:code.priv_dir(:uro)`); deleted
`WeftWarpBurrito.Application` (empty supervisor, unreferenced). Merged
`c_src/{guest,nif,thirdparty,host_test}` and `CMakeLists.txt` into the root
`c_src/` (alongside `taskweft_nif.cpp` from RFD66606-0016). Unified the root
`Makefile` to build both native pieces (`all: taskweft_nif guest nif`).
Dropped the `nmake`/`Makefile.win` branch entirely — `weft_warp_burrito`'s
CMake+Ninja+RISC-V recipe was only ever GNU Make syntax, and both CI jobs
are Linux-only, so `mingw32-make` unconditionally on Windows costs nothing.
Added `{:fine, "~> 0.1", runtime: false}` (needed for `Fine.include_dir()`,
which the CMake `nif` target's `FINE_INCLUDE_DIR` depends on) and removed
`dev_evaluation_deps/0`'s `CI=true` gating entirely — nothing is dev-only
anymore. Added a RISC-V toolchain install step to `.github/workflows/ci.yml`
(`xpack-dev-tools/riscv-none-elf-gcc-xpack` release `v15.2.0-1`,
`linux-x64` asset) — confirmed `cmake`/`ninja-build` already ship on
`ubuntu-latest`, so only the cross-compiler needed adding.
`.github/workflows/casync-interop.yml` needed no change (its job only runs
`mix deps.compile`, never compiles `:uro` itself). Deleted `weft_warp_burrito/`
and `Makefile.win` (fully absorbed); ran `mix deps.unlock --unused` again
(dropped `burrito`/`typed_struct`, no longer needed once `weft_warp_burrito`
the dependency is gone).

## Consequences

Good: `Uro.ReBAC`/planner sandbox NIF code is now fully part of this repo;
no dependency needs `CI=true` gating anymore; `mix.lock` is smaller again
(98 → 95). Bad: `:uro`'s own `mix compile` now unconditionally requires a
RISC-V cross-compiler + CMake + Ninja, everywhere, including every
contributor's local machine and every CI job — a meaningfully heavier build
requirement than before, accepted explicitly per the user's chosen option
over reverting or leaving it half-merged.

## Confirmation

`elixir -e Code.string_to_quoted!`, `mix format --check-formatted`, and YAML
validation pass on all edited files. `mix deps.get` resolves cleanly. Neither
the unified `Makefile` nor the CI RISC-V toolchain step has been exercised
end-to-end anywhere yet — this is new territory combining RISC-V
cross-compilation, CMake/Ninja, and Fine in one build, previously only ever
built as `weft_warp_burrito`'s own isolated (and CI-excluded) dependency.
Relying entirely on CI for first confirmation; expect iteration.

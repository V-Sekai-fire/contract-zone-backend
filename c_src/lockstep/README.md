# Lockstep float-determinism proof of concept (RFD66606-0043)

Not part of the default build (`mix compile`/`make`) -- this is a
manually-run verification exercise proving RFD66606-0041/0042's chosen
approach (Lean4 spec -> CBMC equivalence checking -> RISC-V -> libriscv
execution) actually works, using `Vector3.dot` as the one worked
example. See `docs/decisions/0043-lockstep-float-determinism-poc.md`
for the full writeup and findings.

## Files

- `vector3.h`/`vector3.c` -- `dot_ref`/`dot_good`/`dot_bad`, the guest
  math functions. Freestanding-compatible (no libc calls), so this
  compiles unmodified as a normal host object and as a RISC-V guest ELF.
- `finite_check.h` -- NaN/infinity check via raw bit inspection (CBMC's
  C parser can't handle this toolchain's mingw `<math.h>`).
- `cbmc_associativity.c` -- the tractable, isolated CBMC equivalence
  proof (pure addition, no multiplication).
- `cbmc_equivalence.c` -- the full `Vector3.dot` equivalence claim
  (intractable for CBMC's default float bit-blasting within a few
  minutes at full double range -- a documented limitation, not a
  disproof).
- `../host_test/verify_float_determinism.cpp` -- loads a RISC-V guest
  ELF into this repo's own vendored `libriscv` and compares its output
  against native execution of the identical source.
- `../../lean/LockstepDeterminism.lean` -- the Lean4 spec these C
  implementations are checked against.
- `fixedpoint.h` -- Q32.32 fixed-point `dot_ref`/`dot_bad`, standing in
  for RFD66606-0042's "ban floats entirely" and "fixed-point/integer-only"
  candidates (the same underlying mechanism: no float types, replaced
  by scaled integers).
- `softfloat_mini.h` -- a minimal, illustrative software double-
  precision add/multiply (NOT the production-grade Berkeley SoftFloat,
  BSD-3-Clause, confirmed FOSS, RFD66606-0042's real-world option for this
  strategy), standing in for RFD66606-0042's "softfloat emulation" candidate.
- `validate_softfloat.c` -- sanity-checks `softfloat_mini.h` against
  native hardware double arithmetic (run with `-O0`, see below for why)
  before trusting it for the cross-platform comparison.
- `guest_alt.c` -- exposes the fixed-point and softfloat functions with
  guest-callable signatures (raw `int64_t`/`uint64_t`, not `double`, so
  no hardware float instruction is ever involved on either strategy).
- `../host_test/verify_alt_strategies.cpp` -- the same native-vs-
  libriscv comparison as `verify_float_determinism.cpp`, for these two
  strategies.

## Reproducing the verification

Requires `lean`/`lake` (already used by this org elsewhere), `cbmc`,
and `riscv-none-elf-gcc` -- none of these are project dependencies;
install them yourself to reproduce this.

```sh
# 1. Lean4 spec: prints test vectors and the non-associativity witness.
lean --run lean/LockstepDeterminism.lean

# 2. CBMC: proves dot_good bit-identical to dot_ref (pure addition,
#    tractable); the reassociated direction is expected NOT to verify
#    (see the RFD for why this direction didn't conclude within a
#    reasonable bound in practice, and the concrete counterexample used
#    instead).
cbmc c_src/lockstep/cbmc_associativity.c --gcc --function main
cbmc c_src/lockstep/cbmc_associativity.c --gcc -DREASSOC_BAD --function main

# 3. Cross-compile the SAME source to a freestanding RISC-V64 guest ELF,
#    once with default compiler flags and once with -ffp-contract=off:
riscv-none-elf-gcc -march=rv64gc -mabi=lp64d -static -O2 -ffreestanding \
  -Wl,--undefined=dot_ref -Wl,--undefined=dot_good -Wl,--undefined=dot_bad \
  -nostartfiles c_src/lockstep/vector3.c -o guest_default.elf
riscv-none-elf-gcc -march=rv64gc -mabi=lp64d -static -O2 -ffreestanding \
  -ffp-contract=off \
  -Wl,--undefined=dot_ref -Wl,--undefined=dot_good -Wl,--undefined=dot_bad \
  -nostartfiles c_src/lockstep/vector3.c -o guest_strict.elf

# 4. Build the libriscv comparison harness and run it against both ELFs
#    (native_default.o/native_strict.o are the same vector3.c, compiled
#    for the host with matching -ffp-contract flags -- see the RFD for
#    why BOTH sides must agree on the flag, not just the guest side):
cmake --build build --target verify_float_determinism
./build/verify_float_determinism guest_default.elf
./build/verify_float_determinism guest_strict.elf

# 5. The other two RFD 0042 strategies (fixed-point, softfloat): first
#    sanity-check the softfloat implementation against native hardware
#    arithmetic. Must be built with -O0 -- at -O2 a compiler can
#    constant-fold the literal-double "native" expressions at compile
#    time using higher-than-double precision, which produced a false
#    mismatch here during this RFD's own verification (see the RFD).
clang -O0 c_src/lockstep/validate_softfloat.c -Ic_src/lockstep -o validate_softfloat
./validate_softfloat

# 6. Cross-compile the fixed-point/softfloat guest functions to RISC-V
#    (raw int64/uint64 signatures -- no double anywhere in this ELF at
#    all, so there is no hardware float instruction to diverge):
riscv-none-elf-gcc -march=rv64gc -mabi=lp64d -static -O2 -ffreestanding \
  -Wl,--undefined=fixed_dot_ref_i64 -Wl,--undefined=fixed_dot_bad_i64 \
  -Wl,--undefined=soft_dot_ref_bits -Wl,--undefined=soft_dot_bad_bits \
  -nostartfiles c_src/lockstep/guest_alt.c -o guest_alt.elf

cmake --build build --target verify_alt_strategies
./build/verify_alt_strategies guest_alt.elf

# 7. Automate the "-ffp-contract=off is actually being honored" check
#    from finding 4/step 3 above, using this org's own fire/lean-capstone
#    (a Lean4 Capstone binding) instead of shelling out to
#    riscv-none-elf-objdump -- see lean/CheckNoFma.lean.
cd lean && lake build check_no_fma && cd ..
./lean/.lake/build/bin/check_no_fma guest_default.elf   # expect: 6 FMA instructions found, exit 1
./lean/.lake/build/bin/check_no_fma guest_strict.elf    # expect: OK, 18 instructions scanned, exit 0
```

## What this proved (see the RFD for the full narrative)

- `dot_ref`/`dot_good` (same evaluation order) are bit-identical between
  native x86-64 and libriscv-interpreted RISC-V64, in every
  configuration tested.
- `dot_bad` (deliberately reassociated) diverges from `dot_ref` on both
  sides as expected -- and, with an input exercising an inexact
  multiplication, ALSO diverges between native and guest at default
  compiler flags (confirmed via `objdump`: the default RISC-V build
  fuses into `fmadd.d`). `-ffp-contract=off` on **both** sides
  eliminates this divergence completely.
- An input relying only on exact multiplications (`1.0 * x`) does NOT
  exercise this risk at all -- an earlier pass of this exact
  verification used only that input and drew a false conclusion from an
  unrelated register-read bug in the harness itself (see the RFD). Test
  with an input that actually rounds.
- **Fixed-point and softfloat are both bit-identical between native and
  libriscv unconditionally** (no compiler-flag discipline needed,
  unlike native float) -- but they differ from each other in a way that
  matters: fixed-point's `dot_ref` and `dot_bad` are bit-identical to
  *each other* too (integer arithmetic has no rounding step for
  reassociation to interact with, so the hazard doesn't exist at all),
  while softfloat's `dot_ref`/`dot_bad` still genuinely diverge from
  each other (softfloat faithfully implements the same IEEE 754
  rounding rules as hardware float -- it removes the cross-compiler/
  cross-architecture FMA-contraction risk specifically, not the
  reassociation-matters concern itself).

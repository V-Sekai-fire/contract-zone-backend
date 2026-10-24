---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A -- committed directly, no PR review
labels: sandbox, determinism, lockstep, floating-point, proof-of-concept
---

# 0043 Lockstep float-determinism proof of concept: Lean4 -> CBMC -> RISC-V -> libriscv, all four RFD66606-0042 strategies tested

## Context

RFD66606-0041 chose the verification pipeline (Lean4 spec -> CBMC/`hw-cbmc`
equivalence checking) and RFD66606-0042 chose the float-determinism strategy
(disciplined native IEEE 754 float, not banned/emulated/fixed-point) --
both by scoring and reasoning, not by building anything. This RFD is
that pipeline actually built, once, end-to-end, against a single
concrete primitive (`Vector3.dot`), plus toolchain setup notes and an
honest account of two real bugs found and fixed along the way. It
covers all four of RFD66606-0042's candidates empirically, not just the
winner: disciplined native float (the winner), fixed-point/"ban
floats" (the same underlying mechanism), and a minimal illustrative
softfloat.

**Toolchain**: `lean`/`lake` (already installed), `riscv-none-elf-gcc`
(already installed, globally -- this is the same cross-compiler
RFD66606-0039 removed as a *project build dependency*; using it here to produce
a hand-built verification artifact does not reintroduce that
dependency into `mix compile`/CI). `cbmc` was not installed; its
official Windows MSI installer requires admin privileges this session
didn't have (`Error 1303`), so it was extracted directly from the MSI
archive with 7-Zip instead -- a real, reusable workaround worth
recording, not just "somehow got it working."

## What was built

- `lean/LockstepDeterminism.lean` -- the spec: `Vector3.dot` with a
  fixed evaluation order, `(x*x' + y*y') + z*z'`, plus a concrete
  non-associativity witness.
- `c_src/lockstep/vector3.c` -- three C implementations: `dot_ref`
  (matches the spec's order), `dot_good` (same order, written with
  intermediate named values -- proves the equivalence check isn't
  fooled by cosmetic rewrites), `dot_bad` (a *different*, still
  mathematically-equal-over-the-reals association -- kept permanently
  as a regression case, not a one-off).
- `c_src/lockstep/cbmc_associativity.c` -- the tractable core CBMC
  proof: `(p+q)+r` vs. differently-associated forms, isolating pure
  addition from multiplication.
- `c_src/host_test/verify_float_determinism.cpp` -- loads a RISC-V64
  guest ELF (cross-compiled by hand from the identical `vector3.c`)
  into this repo's own vendored `libriscv`, and compares its output
  against native execution.
- `c_src/lockstep/fixedpoint.h` -- Q32.32 fixed-point `dot_ref`/
  `dot_bad`, standing in for "ban floats entirely" and "fixed-point/
  integer-only" (the same mechanism: no float types, scaled integers).
- `c_src/lockstep/softfloat_mini.h` -- a minimal, illustrative software
  double add/multiply (not the production-grade Berkeley SoftFloat,
  BSD-3-Clause, confirmed FOSS, RFD66606-0042's real-world option), standing
  in for "softfloat emulation."
- `c_src/lockstep/guest_alt.c`, `c_src/host_test/verify_alt_strategies.cpp`
  -- the same native-vs-`libriscv` comparison, for these two strategies.
- `c_src/lockstep/README.md` -- exact reproduction commands.

## Findings

**1. CBMC equivalence checking works, but only at a bounded scope.**
The pure-addition-associativity claim (`cbmc_associativity.c`, 3
nondet doubles bounded to ±1000) verifies in well under two minutes:
`dot_good`-shaped reassociation (same order, different syntax) proves
equivalent; a differently-associated form does not (see below for how
that negative case was actually confirmed). The full 6-variable
`Vector3.dot` claim (`cbmc_equivalence.c`) did not conclude within a
240-second bound at double precision, even with inputs bounded to
±1000 -- CBMC's default float bit-blasting doesn't scale to this
many combined multiply/add operations in reasonable time. This is a
real, documented limitation of the *equivalence-checking step
specifically* (not of the underlying determinism claim -- see finding
3, which validates the same claim by direct execution instead).

**2. The reassociated case's counterexample was found by direct
computation, not by waiting for CBMC's SAT search.** Both the
`cbmc_associativity.c -DREASSOC_BAD` direction and the full
`dot_bad`-vs-`dot_ref` direction failed to conclude (SAT search for a
counterexample, as opposed to UNSAT for the "good" direction, took
meaningfully longer in this CBMC version) within a 240-second bound.
Rather than wait longer, Lean4's `#eval`/`--run` was used to directly
compute several classic candidates and confirm `(1.0, 1.0e16, -1.0e16)`
is a real, concrete witness where `(p+q)+r` and `p+(q+r)` diverge
(`0.0` vs. `1.0`) -- cheap, fast, and just as valid a demonstration for
this RFD's purpose. Full symbolic CBMC coverage of the "bad" direction
remains open, not attempted further here.

**3. `dot_ref`/`dot_good` are bit-identical between native x86-64 and
libriscv-interpreted RISC-V64, in every configuration tested** --
confirming RFD66606-0042's central claim by actual execution, the step that
RFD's own "Non-decision" section called for. This held for both the
default compiler flags and with `-ffp-contract=off` on both sides, on
two different input sets.

**4. A real, confirmed cross-environment divergence for `dot_bad`,
and confirmation that RFD66606-0042's recommended fix eliminates it.**
Using an input set where the multiplications are genuinely inexact in
binary (`0.1 * 0.11` etc., not `1.0 * x`), `dot_bad` produced
**different bit patterns** on native x86-64 (`0.21300000000000002`)
vs. libriscv-hosted RISC-V64 (`0.21299999999999999`) at each platform's
default compiler flags -- confirmed via `objdump` to be `fmadd.d`
(fused multiply-add) contraction on the RISC-V side that the native
build didn't perform. Rebuilding **both** sides with `-ffp-contract=off`
made all three functions, including `dot_bad`, agree bit-for-bit. This
is `-ffp-contract` actually mattering, empirically, not a theoretical
risk cited from RFD66606-0042's literature search.

**5. That divergence does NOT show up with every input.** The first
input set tried (`1.0, 1.0, 1.0, 1.0, 1.0e16, -1.0e16`) -- chosen to
demonstrate non-associativity cleanly -- happens to involve only exact
multiplications (`1.0 * anything` never rounds), so FMA contraction
changes nothing for it; `dot_bad` matched across native/guest at
default flags for *this* input alone. **A verification exercise that
only tests exact-multiplication inputs will not catch this risk** --
`c_src/host_test/verify_float_determinism.cpp` now runs both input
sets for exactly this reason, not just the clean pedagogical one.

## A bug found and fixed along the way, documented rather than
## quietly corrected

An earlier pass of this verification appeared to show `dot_bad`
diverging between native and guest even on the "exact multiplication"
input set -- which would have contradicted finding 5 above. That
result was **wrong**: `verify_float_determinism.cpp` read the guest's
return value from `getfl(0)`, but RISC-V's `fa0` (where a `double`
return value actually lands) is f-register **10** (`REG_FA0`), not
register 0 (`ft0`, an unrelated scratch register the guest functions
never touch). Every "guest" value this bug produced was silently a
stale/default `0.0` -- which coincidentally equalled the correct answer
for `dot_ref`/`dot_good` on that specific input (both happen to
evaluate to `0.0`), making them look like they matched, while `dot_bad`
(whose correct answer is `1.0`) looked like a mismatch that wasn't
real. Caught by a targeted sanity check (`dot_ref(1,2,3,4,5,6)` via
`libriscv`, expected `32`, got `0`) once the "FMA contraction" story
seemed suspicious against the `-ffp-contract=off`-on-both-sides result
that should have resolved it but didn't. Fixed by reading
`getfl(riscv::REG_FA0)` instead of `getfl(0)`; the comment explaining
why is left permanently in the source, not just in this RFD or a
commit message, since the exact same mistake (assuming ABI register
index 0 == argument/return position 0) is easy to make again.

**The lesson generalizes beyond this one bug**: a verification harness
that "confirms" a security- or determinism-relevant finding needs the
same skepticism as the code it's checking. A too-convenient early
result (in this case, one that lined up with what RFD66606-0042 predicted)
was still checked with an independent sanity test before being trusted.

## The other three RFD66606-0042 strategies, empirically tested

Findings 1-5 above and the register-index bug both concern disciplined
native float, the STAR vote's winner. The other three candidates were
built and tested the same way (native-vs-`libriscv` comparison,
`c_src/lockstep/guest_alt.c` + `verify_alt_strategies.cpp`):

**6. Fixed-point and softfloat are both bit-identical between native
and libriscv unconditionally** -- neither needs `-ffp-contract`
discipline the way native float does, confirming RFD66606-0042's own
reasoning for why they were scored as safer-but-costlier alternatives.

**7. Fixed-point eliminates the reassociation hazard entirely, not
just the cross-platform-FMA risk.** With Q32.32 fixed-point,
`dot_ref` and `dot_bad` (the differently-associated form) are
bit-identical to *each other*, not just across platforms -- integer
arithmetic has no rounding step for reassociation to interact with, so
the hazard this whole RFD is about doesn't exist for this strategy at
all. This is the sharpest empirical confirmation of RFD66606-0042's own
scoring rationale ("buys determinism by removing the rounding-order
question entirely, not by controlling it").

**8. Softfloat removes the cross-platform risk but NOT the
reassociation hazard.** Unlike fixed-point, softfloat's `dot_ref` and
`dot_bad` still genuinely diverge from each other (`0.21299999999999999`
vs. `0.21300000000000002`), matching native hardware float's own
behavior exactly -- softfloat faithfully implements the same IEEE 754
rounding rules, it just does so without a hardware FMA instruction for
a compiler to fuse into. This is a real, useful distinction RFD66606-0042's
literature-only comparison couldn't have shown: fixed-point and
softfloat are not interchangeable "safer" options, they trade off
differently. Softfloat still needs the same operation-order discipline
disciplined native float needs; fixed-point doesn't.

**9. A second bug, in the softfloat implementation itself, caught by
its own validation step before being trusted.** `soft_add`'s
normalization logic originally used two sequential shift-direction
while-loops (shift left while a target bit is clear; separately, shift
right if bits above it are set) that could actively fight each other:
a same-sign addition's carry-out could leave the result's highest bit
*above* the target position, and the left-shift loop -- which only
checked "is the target bit clear," with no awareness the value might
already be higher -- would shift further away from correct before the
right-shift loop ever got a chance to run. Caught immediately by
`validate_softfloat.c` (`1.5 + 2.5` computed `0.00390625` instead of
`4`) before this implementation was used for any cross-platform claim.
Fixed by finding the single highest set bit first and shifting exactly
once, in the direction that bit actually requires.

**10. Even the fix's own validation initially looked wrong, for a
third, unrelated reason -- constant folding.** After fixing finding 9,
`validate_softfloat.c`'s full-dot-product comparison (`dot_bad`
specifically) still appeared to mismatch between "native" and "soft"
at `-O2`. This was not a bug in the fix: the test computed "native"
by writing the arithmetic expression inline with literal double
constants, which an optimizing compiler is free to constant-fold at
compile time using higher-than-double precision -- not a genuine
runtime double computation, and therefore not a fair comparison against
the software implementation's real runtime arithmetic. Rebuilding with
`-O0` (forcing genuine runtime double arithmetic) resolved it
immediately; `c_src/lockstep/validate_softfloat.c`'s header comment and
`README.md` both say to build this file with `-O0` specifically,
permanently, not just as a one-off troubleshooting note.

Findings 9 and 10 reinforce the same lesson as the register-index bug:
**every stage of this pipeline needed independent verification before
being trusted, including the verification code itself, twice over in
softfloat's case.**

## Automating the "-ffp-contract discipline" check: `lean/CheckNoFma.lean`

Finding 4's fix (`-ffp-contract=off`) is only as good as the guarantee
that it's actually applied on every build, forever -- a one-time manual
`objdump` check (as findings 4 and this RFD's earlier text described)
doesn't scale, and source review can't catch it at all (nothing in the
C source changes when the compiler decides to fuse). `lean/CheckNoFma.lean`
makes this an automatable, repeatable check: disassemble the compiled
guest ELF's `.text` section and fail if any RV64GC fused multiply-add
opcode (`fmadd.d`/`fmsub.d`/`fnmadd.d`/`fnmsub.d` and the single-
precision forms) is present.

Built using this org's own `fire/lean-capstone` (a Lean4 Capstone
binding) rather than shelling out to `riscv-none-elf-objdump` -- reuses
an owned asset and stays in the same Lean4 tooling this whole pipeline
already depends on. `lean/lakefile.lean` adds it as a `lean-capstone`
dependency (vendoring Capstone from source via `cc`+`ar`, no `cmake`);
`lean/CheckNoFma.lean` implements a minimal ELF64 reader (just enough
to locate `.text` by section name) plus the FMA-mnemonic scan.

**A second real bug found and fixed via this same "verify independently"
discipline**: an initial version, using `Mode.riscv64` alone, decoded
*zero* instructions from a valid, non-empty `.text` section -- not an
error, `cs_disasm` (Capstone's C entry point) silently stops at the
first instruction it cannot decode and returns whatever it managed
before that point. ELF section parsing was confirmed correct first
(cross-checked byte-for-byte against `objdump -h`'s reported offset/
size/address), narrowing the bug to Capstone's mode configuration:
`riscv-none-elf-gcc`'s `-march=rv64gc` output uses both the compressed
("C" extension) and float/double ("F"/"D" extension) instruction
extensions, each requiring its own `cs_mode` bit that `Mode.riscv64`
alone doesn't set. Fixed by combining `Mode.riscv64 ||| Mode.raw (1<<<2)
||| Mode.raw (1<<<3)` (compressed + float/double). **This gap in
`lean-capstone` itself was reported upstream**: `fire/lean-capstone#2`
adds named `Mode.riscvC`/`Mode.riscvFD` constants and a README section,
so a future consumer doesn't have to rediscover this the same way.

Confirmed working against both guest ELFs from finding 4: the default-
flags build reports 6 `fmadd.d` instructions at their exact addresses;
the `-ffp-contract=off` build reports 0 findings across 18 scanned
instructions (not a vacuous empty scan).

## Confirmation

`c_src/host_test/verify_float_determinism.cpp`, built via
`cmake --build build --target verify_float_determinism` (not part of
the default build), run against both a default-flags and a
`-ffp-contract=off` guest ELF -- output reproduced in
`c_src/lockstep/README.md`. `dot_ref`/`dot_good` bit-identical across
native/libriscv in all four combinations tried (2 input sets x 2 flag
configurations); `dot_bad` diverges exactly when expected (inexact-
multiplication input, mismatched or default `-ffp-contract`) and never
otherwise.

`c_src/host_test/verify_alt_strategies.cpp`, built via
`cmake --build build --target verify_alt_strategies`, confirms
fixed-point and softfloat both bit-identical between native and
libriscv unconditionally, with fixed-point additionally eliminating the
`dot_ref`-vs-`dot_bad` divergence entirely (softfloat does not).
`c_src/lockstep/validate_softfloat.c` (built with `-O0`) confirms the
softfloat implementation matches native hardware double arithmetic
across a range of add/multiply/dot-product cases before being trusted
for the cross-platform claim.

`lake build check_no_fma` (in `lean/`) followed by running it against
both guest ELFs from finding 4 confirms 6 FMA instructions detected
(default flags) vs. 0 found across 18 scanned instructions
(`-ffp-contract=off`) -- matching `objdump`'s manually-checked findings
exactly, now automated and reusable.

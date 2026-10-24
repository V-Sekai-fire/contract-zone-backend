// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// Vector3.dot proof-of-concept for RFD66606-0043 (Lean4 -> CBMC -> RISC-V ->
// libriscv verification pipeline, RFD66606-0041/0042's chosen approach).
// Scalar-argument form deliberately, not a Vector3 struct: RISC-V's
// small-aggregate-passing rules (an all-float struct qualifies for
// FPR-only passing only up to 2 fields; a 3-field struct like Vector3
// does not) would need extra care to get right in the CBMC harness and
// the manual libriscv register setup in verify_float_determinism.cpp --
// 6 independent doubles are unambiguously passed in fa0..fa5 under the
// hardware floating-point calling convention, sidestepping that
// question entirely for this proof of concept.
#ifndef VECTOR3_H
#define VECTOR3_H

// Reference: mirrors lean/LockstepDeterminism.lean's fixed evaluation
// order exactly -- (x*x' + y*y') + z*z'. This is the ground truth an
// equivalence-checked guest implementation must match bit-for-bit, not
// just "mathematically equal over the reals" (float addition is
// commutative but NOT associative -- see the RFD for a concrete
// counterexample).
double dot_ref(double ax, double ay, double az, double bx, double by, double bz);

// "Good" candidate: same evaluation order as the reference, written
// with intermediate named values instead of one expression -- proves
// the CBMC equivalence check isn't fooled by superficial rewrites,
// only by actual reassociation.
double dot_good(double ax, double ay, double az, double bx, double by, double bz);

// "Bad" candidate: a *different*, still mathematically-equal-over-the-
// reals association -- x*x' + (y*y' + z*z') instead of
// (x*x' + y*y') + z*z'. Deliberately wrong, kept as a permanent
// regression case: it proves the verification pipeline actually
// catches reassociation drift instead of rubber-stamping anything
// "close enough" -- see the RFD for the concrete FMA-contraction
// divergence this exposed between native x86-64 and RISC-V-via-
// libriscv execution of this exact function.
double dot_bad(double ax, double ay, double az, double bx, double by, double bz);

#endif

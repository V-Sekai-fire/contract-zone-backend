// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
#ifndef FIXEDPOINT_H
#define FIXEDPOINT_H
#include <stdint.h>

// Q32.32 fixed-point: a signed 64-bit integer, low 32 bits are the
// fractional part. Represents "ban floats entirely" and "fixed-point/
// integer-only" as the SAME underlying mechanism (both mean: no float
// types anywhere, replaced by scaled integers) -- one test covers both
// RFD66606-0042 candidates.
typedef int64_t fixed_t;
#define FIXED_SHIFT 32
#define FIXED_ONE ((fixed_t)1 << FIXED_SHIFT)

static inline fixed_t fixed_from_double(double d) {
  return (fixed_t)(d * (double)FIXED_ONE);
}
static inline double fixed_to_double(fixed_t f) {
  return (double)f / (double)FIXED_ONE;
}
static inline fixed_t fixed_mul(fixed_t a, fixed_t b) {
  // 64x64->128-bit product, then shift back down -- avoids overflow
  // for the magnitudes this proof-of-concept exercises. __int128 is a
  // GCC/Clang extension, supported by riscv-none-elf-gcc too.
  __int128 wide = (__int128)a * (__int128)b;
  return (fixed_t)(wide >> FIXED_SHIFT);
}
static inline fixed_t fixed_add(fixed_t a, fixed_t b) { return a + b; }

// Same three functions as c_src/lockstep/vector3.c, fixed-point form.
// Integer add/multiply are exact (no rounding) for values that don't
// overflow, so "ref"/"good"/"bad" (different association order) are
// ALL bit-identical to each other here by construction -- unlike the
// float case, there is no associativity hazard to demonstrate,
// because there is no rounding step for associativity to interact
// with. That itself IS the finding: fixed-point buys determinism by
// removing the rounding-order question entirely, not by controlling it.
static inline fixed_t fixed_dot_ref(fixed_t ax, fixed_t ay, fixed_t az,
                                     fixed_t bx, fixed_t by, fixed_t bz) {
  return fixed_add(fixed_add(fixed_mul(ax, bx), fixed_mul(ay, by)), fixed_mul(az, bz));
}
static inline fixed_t fixed_dot_bad(fixed_t ax, fixed_t ay, fixed_t az,
                                     fixed_t bx, fixed_t by, fixed_t bz) {
  return fixed_add(fixed_mul(ax, bx), fixed_add(fixed_mul(ay, by), fixed_mul(az, bz)));
}

#endif

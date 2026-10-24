// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// RFD66606-0043's other two float-determinism strategies (RFD66606-0042):
// fixed-point ("ban floats"/"integer-only") and a minimal softfloat.
// Freestanding-compatible, same convention as vector3.c -- compiles
// unmodified as a normal host object and as a RISC-V guest ELF.
#include <stdint.h>
#include "fixedpoint.h"
#include "softfloat_mini.h"

// Fixed-point: expose the underlying int64 representation directly
// (not converted back to double) -- exact integer values, no precision
// question at the interface boundary.
int64_t fixed_dot_ref_i64(int64_t ax, int64_t ay, int64_t az, int64_t bx, int64_t by, int64_t bz) {
  return (int64_t)fixed_dot_ref((fixed_t)ax, (fixed_t)ay, (fixed_t)az, (fixed_t)bx, (fixed_t)by, (fixed_t)bz);
}
int64_t fixed_dot_bad_i64(int64_t ax, int64_t ay, int64_t az, int64_t bx, int64_t by, int64_t bz) {
  return (int64_t)fixed_dot_bad((fixed_t)ax, (fixed_t)ay, (fixed_t)az, (fixed_t)bx, (fixed_t)by, (fixed_t)bz);
}

// Softfloat: expose the raw uint64 bit pattern directly (not a native
// double return) -- the whole point is these bits never touch a
// hardware FPU instruction on either side.
uint64_t soft_dot_ref_bits(uint64_t ax, uint64_t ay, uint64_t az, uint64_t bx, uint64_t by, uint64_t bz) {
  return soft_dot_ref(ax, ay, az, bx, by, bz);
}
uint64_t soft_dot_bad_bits(uint64_t ax, uint64_t ay, uint64_t az, uint64_t bx, uint64_t by, uint64_t bz) {
  return soft_dot_bad(ax, ay, az, bx, by, bz);
}

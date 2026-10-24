// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// See vector3.h. Freestanding-compatible (no libc calls) so this
// compiles unmodified both as a normal host object (for CBMC and the
// native side of verify_float_determinism.cpp) and as a RISC-V guest
// ELF (via riscv-none-elf-gcc -ffreestanding, see RFD66606-0043's build
// instructions).
#include "vector3.h"

double dot_ref(double ax, double ay, double az, double bx, double by, double bz) {
  return (ax * bx + ay * by) + az * bz;
}

double dot_good(double ax, double ay, double az, double bx, double by, double bz) {
  double xx = ax * bx;
  double yy = ay * by;
  double zz = az * bz;
  double partial = xx + yy;
  return partial + zz;
}

double dot_bad(double ax, double ay, double az, double bx, double by, double bz) {
  return ax * bx + (ay * by + az * bz);
}

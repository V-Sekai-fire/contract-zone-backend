// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// CBMC equivalence-checking harness (RFD66606-0041/0042/0043's chosen
// verification step): proves dot_good is bit-for-bit identical to
// dot_ref for ALL finite double inputs in a bounded range, not just
// spot-checked test vectors -- bit-pattern comparison via memcmp, not
// `==`, since the property that matters for lockstep is exact
// reproducibility (NaN payloads, -0.0 vs +0.0), not just numeric
// equality.
//
// Run with (see also docs/decisions/0043-*.md and this directory's
// README.md for the full reproduction steps):
//   cbmc vector3.c cbmc_equivalence.c --gcc --function main
//
// Bounded to a realistic game-world coordinate range: full double-
// precision bit-blasting over an unrestricted exponent range is
// intractable for CBMC's default SAT backend in reasonable time (a
// real, documented limitation of this verification step, not a defect
// in the underlying claim -- see the RFD).
#include <string.h>
#include "finite_check.h"
#include "vector3.h"

int main(void) {
  double ax = nondet_double(), ay = nondet_double(), az = nondet_double();
  double bx = nondet_double(), by = nondet_double(), bz = nondet_double();

  __CPROVER_assume(!is_nan_or_inf(ax) && !is_nan_or_inf(ay) && !is_nan_or_inf(az));
  __CPROVER_assume(!is_nan_or_inf(bx) && !is_nan_or_inf(by) && !is_nan_or_inf(bz));
  __CPROVER_assume(ax > -100.0 && ax < 100.0);
  __CPROVER_assume(ay > -100.0 && ay < 100.0);
  __CPROVER_assume(az > -100.0 && az < 100.0);
  __CPROVER_assume(bx > -100.0 && bx < 100.0);
  __CPROVER_assume(by > -100.0 && by < 100.0);
  __CPROVER_assume(bz > -100.0 && bz < 100.0);

  double r_ref = dot_ref(ax, ay, az, bx, by, bz);
  double r_good = dot_good(ax, ay, az, bx, by, bz);

  __CPROVER_assert(memcmp(&r_ref, &r_good, sizeof(double)) == 0,
                    "dot_good must be bit-identical to dot_ref");
  return 0;
}

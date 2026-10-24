// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
#ifndef SOFTFLOAT_MINI_H
#define SOFTFLOAT_MINI_H
#include <stdint.h>
#include <string.h>

// Minimal, illustrative software double-precision add/multiply --
// NOT the production-grade Berkeley SoftFloat (BSD-3-Clause, confirmed
// FOSS, the real-world option RFD66606-0042 named), which handles the full
// IEEE 754 spec (subnormals, all rounding modes, NaN payload
// propagation, infinities). This handles only normal, finite,
// nonzero double operands with round-to-nearest-even, which is all
// this proof-of-concept's test vectors need -- scoped down
// deliberately for a quick empirical check of ONE property: does pure
// integer-based emulation of float semantics give the same result
// regardless of host FPU, unlike native hardware float? A production
// implementation of this strategy would use Berkeley SoftFloat, not
// this.
//
// Validated against native hardware double arithmetic for a range of
// cases in validate_softfloat.c before being trusted for anything
// (see docs/decisions/0043-*.md) -- an earlier version of soft_add had
// a real normalization bug (two sequential shift-direction loops that
// could fight each other, one only checking "is bit 54 clear" with no
// awareness the value might already be ABOVE bit 54) caught this way:
// 1.5 + 2.5 computed 0.00390625 instead of 4. Fixed by finding the
// single highest set bit first and shifting exactly once in the
// correct direction, not two competing loops.
typedef uint64_t sf64;

static inline sf64 sf_from_double(double d) {
  sf64 bits;
  memcpy(&bits, &d, 8);
  return bits;
}
static inline double sf_to_double(sf64 bits) {
  double d;
  memcpy(&d, &bits, 8);
  return d;
}

typedef struct {
  int sign;      // 0 or 1
  int64_t exp;   // unbiased
  uint64_t mant; // 53-bit significand, implicit leading 1 included (bit 52 set)
} sf_decoded;

static inline sf_decoded sf_decode(sf64 bits) {
  sf_decoded d;
  d.sign = (int)(bits >> 63);
  int64_t raw_exp = (int64_t)((bits >> 52) & 0x7FFu);
  uint64_t frac = bits & 0xFFFFFFFFFFFFFull;
  d.exp = raw_exp - 1023;
  d.mant = frac | (1ull << 52); // implicit leading 1 (normal numbers only)
  return d;
}

static inline sf64 sf_encode(int sign, int64_t exp, uint64_t mant53) {
  // mant53 has the implicit leading 1 in bit 52; strip it before packing.
  uint64_t frac = mant53 & 0xFFFFFFFFFFFFFull;
  uint64_t biased = (uint64_t)(exp + 1023);
  return ((uint64_t)sign << 63) | (biased << 52) | frac;
}

// Round-to-nearest-even on a value known via its low bits below the
// kept precision (guard/round/sticky already folded into `sticky`).
static inline uint64_t sf_round_even(uint64_t mant, int guard, int round_bit, int sticky) {
  if (!guard) return mant;
  if (round_bit || sticky) return mant + 1; // > halfway
  return (mant & 1) ? mant + 1 : mant;       // exactly halfway: round to even
}

static inline sf64 soft_mul(sf64 a_bits, sf64 b_bits) {
  sf_decoded a = sf_decode(a_bits);
  sf_decoded b = sf_decode(b_bits);
  int sign = a.sign ^ b.sign;
  int64_t exp = a.exp + b.exp;

  // 53x53-bit product fits in 106 bits -- use unsigned __int128.
  unsigned __int128 product = (unsigned __int128)a.mant * (unsigned __int128)b.mant;
  // product is in [2^104, 2^106) since both operands are in [2^52, 2^53).
  // Normalize so the leading 1 lands at bit 52 of a 53-bit result.
  int top_bit = (product >> 105) ? 105 : 104;
  exp += (top_bit - 104);
  int shift = top_bit - 52;
  uint64_t mant = (uint64_t)(product >> shift);
  unsigned __int128 remainder_mask = ((unsigned __int128)1 << shift) - 1;
  unsigned __int128 remainder = product & remainder_mask;
  int guard = shift > 0 ? (int)((product >> (shift - 1)) & 1) : 0;
  int sticky = (remainder << 1) != 0 && shift > 1
                   ? ((remainder & (((unsigned __int128)1 << (shift - 1)) - 1)) != 0)
                   : 0;
  mant = sf_round_even(mant, guard, 0, sticky);
  if (mant >> 53) { mant >>= 1; exp += 1; } // rounding overflowed into bit 53

  return sf_encode(sign, exp, mant);
}

static inline sf64 soft_add(sf64 a_bits, sf64 b_bits) {
  sf_decoded a = sf_decode(a_bits);
  sf_decoded b = sf_decode(b_bits);

  // Align to the larger exponent, shifting the smaller operand's
  // mantissa right (tracking guard/round/sticky bits lost off the end).
  sf_decoded hi = a, lo = b;
  if (b.exp > a.exp || (b.exp == a.exp && b.mant > a.mant)) { hi = b; lo = a; }
  int64_t exp = hi.exp;
  int shift = (int)(hi.exp - lo.exp);

  // Work in a wider fixed-point: mantissas scaled up by 2 extra bits
  // (guard+round) plus a sticky bit folded in, matching standard
  // softfloat practice for round-to-nearest-even.
  uint64_t hi_mant = hi.mant << 2;
  uint64_t lo_mant;
  int sticky = 0;
  if (shift >= 55) {
    lo_mant = 0;
    sticky = (lo.mant != 0);
  } else {
    uint64_t shifted_out = shift > 0 ? (lo.mant << 2) & ((1ull << shift) - 1) : 0;
    sticky = (shifted_out != 0);
    lo_mant = (shift >= 64) ? 0 : ((lo.mant << 2) >> shift);
  }

  int64_t signed_sum;
  int sign;
  if (hi.sign == lo.sign) {
    signed_sum = (int64_t)(hi_mant + lo_mant);
    sign = hi.sign;
  } else {
    signed_sum = (int64_t)(hi_mant - lo_mant);
    sign = hi.sign;
    if (signed_sum < 0) { signed_sum = -signed_sum; sign = lo.sign; }
  }
  uint64_t sum = (uint64_t)signed_sum;
  if (sum == 0) return 0; // +0.0's bit pattern is exactly 0

  // Normalize: find the highest set bit and shift in ONE direction to
  // put it at bit 54 (mant<<2's implicit-1 position, since hi_mant/
  // lo_mant carry 2 extra guard/round bits). A same-sign add can carry
  // out one extra bit above 54 (needs a right-shift); a cancelling
  // subtraction can lose many leading bits (needs a left-shift) -- an
  // earlier version of this function ran both directions as separate
  // sequential while-loops that could fight each other (a left-shift
  // loop gated only on "is bit 54 clear" doesn't stop just because a
  // HIGHER bit is set, so it kept shifting away from correct before a
  // second loop ever got a chance to correct it) -- confirmed via
  // validate_softfloat.c: 1.5+2.5 produced 0.00390625 instead of 4
  // before this fix. Finding the top bit directly and shifting exactly
  // once, in the right direction, avoids that class of bug entirely.
  int top_bit = 63 - __builtin_clzll(sum);
  if (top_bit > 54) {
    int shift_down = top_bit - 54;
    uint64_t lost_mask = (shift_down >= 64) ? ~0ull : ((1ull << shift_down) - 1);
    sticky |= (sum & lost_mask) != 0;
    sum >>= shift_down;
    exp += shift_down;
  } else if (top_bit < 54) {
    int shift_up = 54 - top_bit;
    sum <<= shift_up;
    exp -= shift_up;
  }

  int guard = (int)((sum >> 1) & 1);
  int round_bit = (int)(sum & 1);
  uint64_t mant = sum >> 2;
  mant = sf_round_even(mant, guard, round_bit, sticky);
  if (mant >> 53) { mant >>= 1; exp += 1; }

  return sf_encode(sign, exp, mant);
}

static inline sf64 soft_dot_ref(sf64 ax, sf64 ay, sf64 az, sf64 bx, sf64 by, sf64 bz) {
  return soft_add(soft_add(soft_mul(ax, bx), soft_mul(ay, by)), soft_mul(az, bz));
}
static inline sf64 soft_dot_bad(sf64 ax, sf64 ay, sf64 az, sf64 bx, sf64 by, sf64 bz) {
  return soft_add(soft_mul(ax, bx), soft_add(soft_mul(ay, by), soft_mul(az, bz)));
}

#endif

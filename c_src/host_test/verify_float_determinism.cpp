// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// RFD66606-0043's actual "run through libriscv, verify bit-identical output"
// step (RFD66606-0042's own recommendation): loads a RISC-V64 guest ELF
// (c_src/lockstep/vector3.c, cross-compiled by riscv-none-elf-gcc --
// see this repo's docs/decisions/0043-*.md and c_src/lockstep/README.md
// for the exact build commands) into this project's own vendored
// libriscv, calls dot_ref/dot_good/dot_bad with two input sets, and
// confirms libriscv's RV64GC double-precision arithmetic produces the
// SAME bit pattern as native x86-64 execution of the identical source
// -- not a same-platform sanity check, an actual cross-execution-
// environment comparison.
//
// Two input sets, deliberately different in kind:
//   "cancellation": exact multiplications (1.0 * anything), isolating
//     pure summation non-associativity. dot_ref/dot_good/dot_bad all
//     agree across native/guest here regardless of compiler flags,
//     because none of the multiplications round -- this input alone
//     would UNDER-claim what's at risk (see the RFD for how this was
//     discovered: an earlier register-read bug in this exact file
//     produced a false "FMA divergence" finding using this input set
//     alone, which further testing disproved).
//   "inexact-mul": genuinely irrational-in-binary multiplicands
//     (0.1/0.3/0.7 style). Here dot_bad's guest and native results
//     DO diverge at the default -ffp-contract setting (confirmed via
//     objdump: the default build fuses into fmadd.d on RISC-V), and
//     -ffp-contract=off (built into two separate guest/native ELFs,
//     see the RFD for the exact build matrix) resolves it completely.
//     This is the input set that actually exercises RFD66606-0042's stated
//     risk -- run BOTH, don't rely on "cancellation" alone.
//
// Not part of the default CMake build (mirrors this project's existing
// convention for standalone verification tools -- see verify_guest.cpp
// before its RFD66606-0039 retirement): build explicitly with
//   cmake --build build --target verify_float_determinism
// This deliberately does NOT reintroduce a riscv-none-elf-gcc build
// dependency into `mix compile`/CI the way RFD66606-0039 removed -- the
// guest ELF this harness loads is built by hand, once, for this
// specific verification exercise, not by the app's own build pipeline.
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <fstream>
#include <sstream>
#include <vector>

#include <libriscv/machine.hpp>

using Machine64 = riscv::Machine<riscv::RISCV64>;

// Native reference: the same source (c_src/lockstep/vector3.c) compiled
// for the host architecture by whatever compiler builds this harness --
// standing in for the Godot client's native execution, compared against
// this repo's libriscv-hosted "guest" execution of the identical source.
extern "C" {
double dot_ref(double ax, double ay, double az, double bx, double by, double bz);
double dot_good(double ax, double ay, double az, double bx, double by, double bz);
double dot_bad(double ax, double ay, double az, double bx, double by, double bz);
}

namespace {

double call_guest(Machine64& machine, const char* fn, double ax, double ay, double az,
                   double bx, double by, double bz) {
  auto addr = machine.memory.resolve_address(fn);
  machine.cpu.reset_stack_pointer();
  machine.setup_call(ax, ay, az, bx, by, bz);
  machine.simulate_with<true>(1'000'000ull, 0u, addr);
  // fa0 is RISC-V f-register 10 (REG_FA0), NOT index 0 -- index 0 is
  // ft0, an unrelated scratch register that's never written by these
  // functions. Reading getfl(0) instead of getfl(REG_FA0) was the
  // actual bug behind this file's own earlier false "FMA divergence"
  // finding on the "cancellation" input set (it silently read back a
  // stale/default 0.0 for every guest call, which happened to equal
  // the correct answer for dot_ref/dot_good on that input by
  // coincidence, but not for dot_bad) -- worth leaving this comment
  // here permanently, not just in the fix's commit message.
  return machine.cpu.registers().getfl(riscv::REG_FA0).f64;
}

bool bit_equal(double a, double b) {
  uint64_t ba, bb;
  std::memcpy(&ba, &a, 8);
  std::memcpy(&bb, &b, 8);
  return ba == bb;
}

struct Inputs {
  const char* name;
  double ax, ay, az, bx, by, bz;
};

bool run_case(Machine64& machine, const Inputs& in) {
  double native_ref = dot_ref(in.ax, in.ay, in.az, in.bx, in.by, in.bz);
  double native_good = dot_good(in.ax, in.ay, in.az, in.bx, in.by, in.bz);
  double native_bad = dot_bad(in.ax, in.ay, in.az, in.bx, in.by, in.bz);

  double guest_ref = call_guest(machine, "dot_ref", in.ax, in.ay, in.az, in.bx, in.by, in.bz);
  double guest_good = call_guest(machine, "dot_good", in.ax, in.ay, in.az, in.bx, in.by, in.bz);
  double guest_bad = call_guest(machine, "dot_bad", in.ax, in.ay, in.az, in.bx, in.by, in.bz);

  std::printf("[%s]\n", in.name);
  std::printf("  native: ref=%.17g good=%.17g bad=%.17g\n", native_ref, native_good, native_bad);
  std::printf("  guest:  ref=%.17g good=%.17g bad=%.17g\n", guest_ref, guest_good, guest_bad);

  bool ref_matches = bit_equal(native_ref, guest_ref);
  bool good_matches = bit_equal(native_good, guest_good);
  bool bad_matches = bit_equal(native_bad, guest_bad);

  std::printf("  ref bit-identical: %d  good bit-identical: %d  bad bit-identical: %d\n",
              ref_matches, good_matches, bad_matches);

  // Only ref/good are required to always match: dot_bad's cross-
  // environment agreement depends on -ffp-contract discipline, which
  // is the entire point being demonstrated here, not an invariant this
  // harness should assert -- see the RFD for the flag matrix.
  return ref_matches && good_matches;
}

} // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <path-to-guest-elf>\n", argv[0]);
    return 2;
  }
  std::ifstream f(argv[1], std::ios::binary);
  if (!f) {
    std::fprintf(stderr, "could not open %s\n", argv[1]);
    return 2;
  }
  std::ostringstream ss;
  ss << f.rdbuf();
  std::string elf = ss.str();
  std::vector<uint8_t> elfBytes(elf.begin(), elf.end());

  Machine64 machine(elfBytes, riscv::MachineOptions<riscv::RISCV64>{.memory_max = 16UL << 20});

  bool ok = true;
  ok &= run_case(machine, {"cancellation", 1.0, 1.0, 1.0, 1.0, 1.0e16, -1.0e16});
  ok &= run_case(machine, {"inexact-mul", 0.1, 0.3, 0.7, 0.11, 0.37, 0.13});

  std::printf("\n%s\n", ok ? "CORE DETERMINISM CLAIMS HOLD (ref/good bit-identical in both cases)"
                           : "CORE CLAIM FAILED");
  return ok ? 0 : 1;
}

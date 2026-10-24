// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// The BEAM-facing boundary: an erl_nif wrapping one libriscv::Machine
// per Program resource, running RISC-V ELFs that use the tagged-
// GuestValue host-call ABI (RFD66606-0018). Deliberately thin: construct/
// destroy a Machine, run an exported function with a caller-supplied
// fuel (gas) budget, and trampoline back to Elixir whenever the guest
// ecalls the host-math syscall for arithmetic Elixir's native
// arbitrary-precision integers must compute (bignum overflow).
//
// "Pause" here is actor-level, not instruction-level: WeftWarpBurrito.
// Program only ever runs one call at a time and is fully idle between
// calls - "pause between gas-metered calls", not "pause mid-
// instruction". See rfd/0002 for the true mid-execution resume design
// this doesn't implement.
//
// Scheduling note: these are dirty NIFs (see the FINE_NIF flags below)
// - guest execution is CPU-bound and fuel-bounded but not time-bounded,
// so it must not run on a normal BEAM scheduler thread.
//
// Bindings use Fine (elixir-nx/fine) rather than hand-written erl_nif
// argument/resource marshalling - see rfd/0003 for why: it reuses
// libriscv as the guest execution substrate unchanged and only
// replaces the binding-layer boilerplate (path/atom decoding, resource
// type registration) with Fine's generated equivalent.
#include <fine.hpp>

#include <cstdint>
#include <memory>
#include <string>
#include <tuple>
#include <variant>
#include <vector>

#include <libriscv/machine.hpp>

namespace {

using Machine64 = riscv::Machine<riscv::RISCV64>;
using gaddr_t = riscv::address_type<riscv::RISCV64>;

// Maps a libriscv MachineException to an Elixir-facing reason atom -
// gas_exhausted is the one callers are expected to actually branch on
// (it means "raise the fuel budget and retry"); everything else is a
// real guest fault (illegal instruction, out-of-memory, etc.) that
// retrying with more fuel will not fix.
fine::Atom machineExceptionToAtom(const riscv::MachineException& e) {
	if (dynamic_cast<const riscv::MachineTimeoutException*>(&e) != nullptr) {
		return fine::Atom("gas_exhausted");
	}
	return fine::Atom("guest_trap");
}

} // namespace

// --- Compiled-program resource + host-call trampoline (RFD66606-0018) ---
//
// RISC-V ELFs using the tagged-GuestValue host-call ABI (originally
// produced by the in-repo s7 AOT compiler, c_src/s7 -- retired, RFD
// 0040, once its two callers turned out not to need a RISC-V sandbox;
// this generic trampoline is kept for a future genuinely-untrusted-
// content guest program using the same ABI). These programs may ecall
// the host-math syscall (600) mid-execution when fixnum arithmetic
// overflows or touches a bignum handle. The handler cannot compute the
// answer here - the whole point (RFD66606-0018) is that Elixir's native
// arbitrary-precision integers do the math - so it stops the Machine
// (state persists in this resource), the NIF returns
// {:host_call, op, a, b} to the owning GenServer, and
// program_resume_nif() injects the result and continues execution.
//
// The exported-function names callable here come from ELFs we compile
// ourselves (never untrusted input); WeftWarpBurrito.Program's API is
// the gate.
class ProgramResource {
public:
	explicit ProgramResource(std::vector<uint8_t> elf) : elfBytes(std::move(elf)) {
		machine = std::make_unique<Machine64>(
			elfBytes, riscv::MachineOptions<riscv::RISCV64>{ .memory_max = 64UL << 20 });
		machine->set_userdata(this);
	}

	// Machine's constructor takes the ELF image as a view
	// (std::string_view / span / const vector&), not an owned copy - it
	// keeps pointers into this buffer for the Machine's whole lifetime
	// (zero-copy ELF loading), so the bytes must outlive the Machine.
	// Members destruct in reverse declaration order, so declaring
	// elfBytes first means machine is destroyed first, elfBytes last.
	std::vector<uint8_t> elfBytes;
	std::unique_ptr<Machine64> machine;

	// Host-call trampoline state, set by the syscall handler.
	bool pending = false;
	int64_t pending_op = 0;
	int64_t pending_a = 0;
	int64_t pending_b = 0;
	gaddr_t pending_pc = 0;
	uint64_t fuel = 0;
};

FINE_RESOURCE(ProgramResource);

namespace {

constexpr size_t kSyscallHostMath = 600; // must match the GuestValue ABI the caller's ELF uses

void install_host_math_handler_once() {
	static bool installed = false;
	if (installed) return;
	installed = true;
	Machine64::install_syscall_handler(kSyscallHostMath, [](Machine64& machine) {
		auto* program = machine.get_userdata<ProgramResource>();
		auto [op, a, b] = machine.sysargs<int64_t, int64_t, int64_t>();
		program->pending = true;
		program->pending_op = op;
		program->pending_a = a;
		program->pending_b = b;
		program->pending_pc = machine.cpu.pc();
		machine.stop();
	});
}

// Shared tail of call/resume: either the guest finished (result in a0)
// or it stopped at a host-math ecall (trampoline back to Elixir).
fine::Term program_finish(ErlNifEnv* env, ProgramResource& program) {
	Machine64& machine = *program.machine;
	if (program.pending) {
		return fine::encode(env, std::make_tuple(fine::Atom("host_call"), program.pending_op,
		                                          program.pending_a, program.pending_b));
	}
	return fine::encode(env, fine::Ok(static_cast<int64_t>(machine.cpu.reg(riscv::REG_ARG0))));
}

std::variant<fine::Ok<fine::ResourcePtr<ProgramResource>>, fine::Error<fine::Atom>>
new_program_nif(ErlNifEnv*, std::string elf_binary) {
	install_host_math_handler_once();
	std::vector<uint8_t> elfBytes(elf_binary.begin(), elf_binary.end());
	try {
		return fine::Ok(fine::make_resource<ProgramResource>(std::move(elfBytes)));
	} catch (const std::exception&) {
		return fine::Error(fine::Atom("bad_elf"));
	}
}

FINE_NIF(new_program_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Term program_call_nif(ErlNifEnv* env, fine::ResourcePtr<ProgramResource> resource,
                            std::string function, std::vector<int64_t> args, uint64_t fuel) {
	ProgramResource& program = *resource;
	Machine64& machine = *program.machine;
	try {
		if (args.size() > 8) {
			return fine::encode(env, fine::Error(fine::Atom("too_many_args")));
		}
		gaddr_t funcAddr = machine.memory.resolve_address(function.c_str());
		if (funcAddr == 0) {
			return fine::encode(env, fine::Error(fine::Atom("no_such_function")));
		}
		machine.cpu.reset_stack_pointer();
		for (size_t i = 0; i < args.size(); ++i) {
			machine.cpu.reg(riscv::REG_ARG0 + static_cast<int>(i)) =
				static_cast<gaddr_t>(args[i]);
		}
		machine.cpu.reg(riscv::REG_RA) = machine.memory.exit_address();
		program.pending = false;
		program.fuel = fuel;
		machine.simulate_with<true>(fuel, 0u, funcAddr);
		return program_finish(env, program);
	} catch (const riscv::MachineException& e) {
		return fine::encode(env, fine::Error(machineExceptionToAtom(e)));
	} catch (const std::exception&) {
		return fine::encode(env, fine::Error(fine::Atom("guest_trap")));
	}
}

FINE_NIF(program_call_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Term program_resume_nif(ErlNifEnv* env, fine::ResourcePtr<ProgramResource> resource,
                              int64_t result) {
	ProgramResource& program = *resource;
	Machine64& machine = *program.machine;
	try {
		if (!program.pending) {
			return fine::encode(env, fine::Error(fine::Atom("not_pending")));
		}
		program.pending = false;
		// Depending on where libriscv's dispatch loop stopped, the PC may
		// still point AT the ecall (which would re-execute it) - skip past
		// it if so. Robust against either stop-point behavior.
		if (machine.cpu.pc() == program.pending_pc) {
			machine.cpu.jump(program.pending_pc + 4);
		}
		machine.cpu.reg(riscv::REG_ARG0) = static_cast<gaddr_t>(result);
		machine.simulate_with<true>(program.fuel, 0u, machine.cpu.pc());
		return program_finish(env, program);
	} catch (const riscv::MachineException& e) {
		return fine::encode(env, fine::Error(machineExceptionToAtom(e)));
	} catch (const std::exception&) {
		return fine::encode(env, fine::Error(fine::Atom("guest_trap")));
	}
}

FINE_NIF(program_resume_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND);

} // namespace

FINE_INIT("Elixir.WeftWarpBurrito.SandboxNif");

---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: rebac, sandbox, config-flip, strangler-fig
---

# 0022 ReBAC in compiled Scheme: SandboxAdapter, differential tests, config-flip

## Context

Stage 4 of the sandbox roadmap: prove the s7 AOT compiler
([[0019-s7-aot-compiler-no-cross-toolchain]]) and its GuestValue handle
trampoline ([[0021-guestvalue-handle-syscalls]]) can run real business
logic, not just synthetic test programs. `Uro.ReBAC`
([[0015-extract-taskweft-rebac-and-sandbox-into-lib]]'s strangler-fig
facade) is the natural target: it already resolves through
`Uro.Ports.ReBAC`, a 3-callback behaviour (`new_graph/0`, `add_edge/4`,
`check_rel/4`), with `Uro.ReBAC.TaskweftAdapter` (wrapping the native
`tw_rebac.hpp` NIF) as the sole real implementation.

`Uro.Ports.ReBAC.check_rel/4` only ever needs `check_base` semantics
(direct edge, transitive `IS_MEMBER_OF`, `CONTROLS`-via-`DELEGATED_TO`
inversion) — `Taskweft.ReBAC.check_rel` always builds a
`{"type":"base",...}` expression, never `union`/`intersection`/
`difference`/`tuple_to_userset`. That is the entire port surface.

## Decision Outcome

`c_src/s7/fixtures/rebac.scm`: `check-rel` ported from
`standalone/tw_rebac.hpp`'s `check_base`, compiled to a RISC-V ELF
(`priv/rebac.elf`) by the existing `s7fixtures` Makefile target. The
graph is a host-owned Elixir list of `[subj, obj, rel]` lists — a
GuestValue handle the guest walks one cons cell at a time via
car/cdr/null? (RFD66606-0021), never copied into guest memory. One
subset-driven design choice: this Lisp-1 has no string literals (the
reader has no `Str` kind), so the three relation-name constants the
algorithm itself must recognize (`IS_MEMBER_OF`, `CONTROLS`,
`DELEGATED_TO`) are passed in by the caller as a boxed `rel-consts`
list rather than embedded in the program — `Uro.ReBAC.SandboxAdapter`
owns that fixed vocabulary, not the guest.

`Uro.ReBAC.SandboxAdapter` implements `Uro.Ports.ReBAC`: `new_graph`/
`add_edge` are pure Elixir (no guest call — building the edge list
costs nothing); `check_rel` calls the named
`Uro.ReBAC.SandboxAdapter.Program` (one `WeftWarpBurrito.Program`
GenServer, RFD66606-0018) with `[graph, subj, rel, obj, rel_consts]`.

**Config-flip**: `Uro.Application` only starts
`Uro.ReBAC.SandboxAdapter.Program` when
`Application.get_env(:uro, :rebac_adapter) == Uro.ReBAC.SandboxAdapter`
— the same config value `Uro.ReBAC.adapter/0` already reads. Setting
one config key both selects the adapter in the facade and boots its
sandbox dependency; the default (`TaskweftAdapter`) boots nothing extra
and never depends on `priv/rebac.elf` existing.

## Consequences

Good: real, previously-native business logic now runs end to end
inside the sandbox with no ABI or trampoline changes; the flip is a
single config value with no code-path branching elsewhere; unselected,
the sandbox path costs nothing at boot. Bad: `check_rel` now costs a
GenServer round-trip plus N host round-trips (one per edge scanned) per
call instead of an in-process NIF call — fine for the graph sizes this
port targets (dozens of edges per permission check), not a drop-in
replacement for large-graph ReBAC workloads without further tuning
(index-like acceleration analogous to `tw_rebac.hpp`'s
`subj_idx`/`member_edges` would need new host ops, not attempted here).

## Confirmation

`verify_rebac` (10 cases: direct match/miss, wrong relation, transitive
membership one and two hops deep, `CONTROLS` delegation present/absent,
empty graph, membership-without-relation) agrees three ways (hand-written
reference oracle mirroring `tw_rebac.hpp` == IR interpreter oracle ==
compiled RISC-V execution) for all 10.
`test/uro/re_bac_sandbox_differential_test.exs` runs the same shapes
(plus the real `Uro.VSekai` zone-entry graph shape) through both
`TaskweftAdapter` and `SandboxAdapter` and asserts agreement.

---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A -- committed directly, no PR review
labels: planner, rebac, sandbox, strangler-fig
---

# 0039 Retire the s7 sandbox: ReBAC/Planner become plain Elixir; `Uro.Planner.SandboxAdapter` gains scan methods first, then is itself retired

## Context

RFD66606-0023 landed `Uro.Planner.SandboxAdapter` (Stage 5A: HTN search plus
domain evaluation, compiled Scheme running in the libriscv guest),
explicitly deferring scan methods (Stage 5B) and ReBAC-based goal
bindings (Stage 5C) as follow-on work. This RFD's first half closed
Stage 5B: `c_src/s7/fixtures/planner.scm` gained scan-method support
(a `methods` table entry is either a plain alternatives list or a scan
definition -- `over`/`recurse`/`branches`/`done`/`done_subtasks` --
distinguished structurally since the entry's car is a pair for
alternatives and an atom for a scan def), plus one new host primitive,
`hash-table-keys` (op 29), needed because Stage 5A's `methods` table
had no way to enumerate a state variable's keys at guest runtime.

**That work shipped, then was immediately superseded.** Once Stage 5B
was working, the question of what else needed sandboxing came up
directly: ReBAC graphs and planner domains are trusted, bundled content
(bundled `.jsonld` files, application-authored group/relation data),
never adversarial input -- exactly the same realization RFD66606-0026 already
reached for combat/loot/progression. Running the HTN search, its
expression evaluator, and the ReBAC graph walk through a custom
Scheme-to-RISC-V AOT compiler (`c_src/s7`, RFD66606-0019) and a libriscv
guest was real infrastructure (a hand-rolled lexer/codegen/register-
allocator/ELF-builder, a tagged-GuestValue host-call ABI, RFD66606-0018/
0021) built to contain a threat that doesn't exist for this content.

## Decision Outcome

- **`Uro.ReBAC.ElixirAdapter`** and **`Uro.Planner.ElixirAdapter`**
  (both new, plain Elixir) replace `Uro.ReBAC.SandboxAdapter` and
  `Uro.Planner.SandboxAdapter` as the default `:rebac_adapter`/
  `:planner_adapter`. Each is a direct, mechanical translation of its
  retired `.scm` fixture's semantics -- same search order (`TwGoal`
  splices `subtasks ++ [goal] ++ remaining`; `TwMultiGoal` tries every
  unmet binding; compound `TwCall` splices with no self-re-append; fuel
  spends only on real branching, never on primitive-action or already-
  satisfied-goal advancement), same scan-method behavior (branch
  priority: every key of one branch before the next branch), same
  fuel=8 ReBAC recursion bound. Elixir's own truthiness (`false`/`nil`
  vs. everything else) maps cleanly onto the Scheme convention the
  ports relied on (only `#f` is false, so `[]` -- the empty plan -- is
  a legitimate success), so no bridging logic was needed there.
- **One real feature addition made during the port, not a straight
  translation**: `Uro.Planner.ElixirAdapter` supports a `"get"` node
  whose pointer's key segment is a single `"{name}"` template (e.g.
  `"/npcs/{_key}"`), resolved against the current params at eval time.
  Stage 5A/5B's `parse_pointer` never supported this (fixed `/var/key`
  only); without it, a scan branch's `check`/`subtasks` could reference
  *which* key is being scanned but never *read the value stored at that
  key* -- which is what most real scan-method domains actually need
  (e.g. "is the npc at this key hostile?"). Ordinary `bind` pointers
  still don't support templating -- only `"get"` nodes do, and only a
  single whole-segment template, not native's multi-template string
  interpolation.
- **`c_src/s7`** (the in-repo s7-subset-to-RISC-V AOT compiler: reader,
  codegen, IR interpreter, RISC-V codegen, ELF builder, `s7c` CLI, the
  `rebac.scm`/`planner.scm` fixtures, and the `verify_rebac`/
  `verify_planner`/`verify_s7`/`verify_s7_fidelity` host-test harnesses)
  is deleted entirely, along with the `s7fixtures` Makefile/CMake
  targets. Nothing else depended on it.
- **`WeftWarpBurrito.Sandbox`** (the fixed-capability
  `:loot_roll`/`:combat_replay`/`:progression_replay` GenServer),
  `c_src/guest/` (the RISC-V guest program embedding the real upstream
  s7 interpreter plus the `loot.scm`/`combat.scm`/`progression.scm`
  content and their `record-macros.scm`), and `c_src/thirdparty/s7`
  (the vendored upstream s7 interpreter source) are also deleted.
  These were already dead code: RFD66606-0026/0027 moved combat/loot/
  progression off the sandbox and onto `Uro.LoopCore.Instance` (plain
  Elixir) in an earlier session, leaving `WeftWarpBurrito.Sandbox`
  with no remaining caller or test. Their continued presence no longer
  had a reason once the ReBAC/Planner sandbox adapters -- the last
  things that made "keep a RISC-V guest toolchain around" worth its
  weight -- were also gone.
- **`WeftWarpBurrito.Program`** (the generic tagged-GuestValue host-call
  trampoline actor, RFD66606-0018) and its NIF half
  (`c_src/nif/weft_sandbox_nif.cpp`'s `ProgramResource`/
  `program_call_nif`/`program_resume_nif`) are KEPT, trimmed of the
  now-dead `SandboxResource`/`call_capability_nif` code. Nothing calls
  `Program` today (its only two callers are this RFD's ReBAC/Planner
  removals), but it remains real, generically useful infrastructure --
  a libriscv::Machine wrapper with bignum-crossing-the-boundary host
  math -- for a future genuinely-untrusted-content guest program, without
  requiring a bespoke compiler to feed it.
- The root `Makefile`'s `guest` target (and its `riscv-none-elf-gcc`
  cross-compiler invocation) is gone entirely -- the `nif` target
  (CMake+Ninja, host `g++`/`llvm-mingw`, no cross-toolchain) is now the
  whole native build. This closes the loop the original s7-compiler
  motivation (RFD66606-0019's "fighting the external riscv-none-elf-gcc
  toolchain") opened: with no guest program left that needs it, the
  cross-compiler dependency itself is gone, not just avoided.

## Consequences

Good: two previously-sandboxed subsystems are now plain, directly
debuggable, directly testable Elixir with zero guest-ABI plumbing
(no atom interning, no tagged-list wire format, no fuel-via-ecall);
`c_src/s7` (a whole hand-rolled compiler) plus the now-dead fixed-
capability sandbox and its vendored upstream interpreter are gone,
substantially shrinking this repo's native surface; the
`riscv-none-elf-gcc` cross-toolchain dependency this whole effort
originally existed to route around is no longer needed for anything.
`WeftWarpBurrito.Program` survives as real, tested-by-history
infrastructure for the day a genuinely untrusted guest program shows
up, without carrying a bespoke compiler as a prerequisite.

Bad: `Uro.Planner.ElixirAdapter` still has the same explicitly-scoped
gaps Stage 5A/5B had (no ReBAC-based goal bindings, no `enums`, no
floating-point values, no KHR_interactivity node beyond `eq`/`lt`/
`add`/`sub`/`not`/`and`/`or`/`get`) -- a plain-Elixir port removes the
*reason* those gaps existed (no more float-free RISC-V ABI to work
around) but doesn't itself close them; closing them is separate,
not-yet-scoped work if a real domain needs them.

## Confirmation

`test/uro/re_bac_elixir_adapter_test.exs` and
`test/uro/planner_elixir_adapter_test.exs` (renamed from their
`*_sandbox_differential_test.exs` predecessors) pin the same plans/
relation checks the sandboxed adapters already proved correct, plus new
scan-method coverage (branch priority across keys, `done_subtasks`
fallback, `recurse` re-appending the scanning task, and the `"get"`
node key-templating addition). Full suite green after every deletion
(`c_src/s7`, `c_src/guest`, `c_src/thirdparty/s7`,
`WeftWarpBurrito.Sandbox`): 133 passed, 2 excluded.

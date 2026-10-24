---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: taskweft, planner, rebac, elixir-port
---

# 0038 Retire the native `taskweft_nif`; sandbox adapters become the only ones

## Context

RFD66606-0022 (ReBAC) and RFD66606-0023 (Planner, Stage 5A) built compiled-Scheme
sandbox adapters as config-flippable alternatives to the native
`taskweft_nif.cpp`/`standalone/` C++ NIF, proven equivalent via
differential tests before ever touching the production default. Every
other file in `standalone/` that wasn't itself the native search engine
has since been ported to plain Elixir (RFD66606-0026/0028-0037) or
documented as intentionally not ported (RFD66606-0031, RFD66606-0036). What remained
was the decision point RFD66606-0022/0023 always deferred: actually flipping
the default and deleting the native path.

The planner sandbox is Stage 5A only — it does not support scan
methods or ReBAC-based goal bindings (RFD66606-0023's own Stage 5B/5C,
explicitly follow-on work), and raises a clear error rather than
misbehaving if a domain needs them. This is a real feature gap, not
just a formality, so this decision was confirmed with the repo owner
before proceeding rather than executed as a purely mechanical cleanup
step.

## Decision Outcome

Flip both config-flip defaults to the sandbox adapters and delete the
native path entirely:

- `config/config.exs`: `:rebac_adapter` → `Uro.ReBAC.SandboxAdapter`,
  `:planner_adapter` → `Uro.Planner.SandboxAdapter` (previously
  `Uro.ReBAC.TaskweftAdapter`/`Uro.Planner.TaskweftAdapter`).
- `Uro.ReBAC`/`Uro.Planner` facades' hardcoded fallback defaults
  updated to match, in case `Application.get_env/3` is ever called
  before config loads.
- Deleted: `Uro.ReBAC.TaskweftAdapter`, `Uro.Planner.TaskweftAdapter`,
  `Taskweft.NIF`, `Taskweft.ReBAC`, `c_src/taskweft_nif.cpp`, and the
  entire `standalone/` directory (the C++20 native planner/ReBAC engine
  and its supporting types).
- `Makefile`: removed the `libtaskweft_nif` build target and the
  `-Istandalone` include path; `all`/`clean` no longer reference it.
- `test/uro/re_bac_sandbox_differential_test.exs` and
  `test/uro/planner_sandbox_differential_test.exs`: previously ran
  every case through both adapters asserting agreement; now pin the
  sandbox adapter's output directly (the same expected values the
  differential comparison already proved correct) since there is no
  longer a second adapter to compare against.

## Consequences

Good: `standalone/`'s ~4,700 lines of native C++ (tagged-union JSON,
ordered-map state, HTN search, ReBAC graph engine, HRR, retrieval,
Monte Carlo execution, plan-memory bridge, explain trees) are gone from
the build, replaced by either a much smaller compiled-Scheme program
(RFD66606-0022/0023) or plain, directly-testable Elixir modules
(RFD66606-0026-0037) — one fewer C++ toolchain dependency, one fewer NIF
surface to keep memory-safe.

Bad, accepted knowingly: any real domain that needs scan methods or
ReBAC-based goal bindings (Stage 5B/5C, not yet built) will now hit a
loud `raise` from `Uro.Planner.SandboxAdapter` instead of silently
working via the native fallback. No current caller in this repo is
known to need either feature — `Uro.VSekai.EntityPlanner`'s only
production domains predate this whole port series and already had a
separate, pre-existing "wrong JSON-LD key schema" bug (documented in
RFD66606-0023's own Context section) that made them fail to load even under
the native adapter, so this flip does not newly break a working
production path. If Stage 5B/5C are needed later, `planner.scm`
(RFD66606-0023) is where that work lands — there is no native fallback left
to fall back to.

## Confirmation

Full `mix test` suite green after the flip (facade default tests,
sandbox differential/regression suites, every RFD66606-0026-0037 module's
own test suite, and the broader application test suite that exercises
`Uro.ReBAC`/`Uro.Planner` through real call sites like
`Uro.VSekai.can_enter_zone?/2` and `Uro.Helpers.UserContentHelper`'s
upload-permission checks). `standalone/` no longer exists in the
working tree; `git status` after this change shows only the deletions
and the config/facade/build-file edits, no orphaned references to
`Taskweft.NIF`/`Taskweft.ReBAC`/`*.TaskweftAdapter` remain in `lib/` or
`test/`.

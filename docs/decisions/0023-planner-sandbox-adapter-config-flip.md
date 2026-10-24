---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: planner, htn, sandbox, config-flip, strangler-fig
---

# 0023 HTN planner in compiled Scheme: SandboxAdapter, differential tests, config-flip

## Context

The final piece of taskweft's reachable surface: `Uro.Planner`
(`lib/uro/ports/planner.ex`, 1-callback: `plan(domain_json) -> term()`),
wrapping `Taskweft.NIF.plan/1` -> `TwLoader::load_domain`
(`standalone/tw_loader.hpp`) -> `tw_plan`/`tw_seek_plan`
(`standalone/tw_planner.hpp`) — a depth-first HTN planner with
backtracking over method/goal/multigoal decomposition, plus a
~80-primitive floating-point expression evaluator (glTF
KHR_interactivity style) used to evaluate action effects and method
guards.

**Pre-existing bug found during investigation, out of scope here:**
`load_domain`'s key whitelist only accepts `variables`/`actions`/
`methods`/`todo_list`/... — both real fixtures
(`priv/domains/jellyfish_common.jsonld`, `jellyfish_bioluminescent.jsonld`)
use the *old*, pre-rename keys `state`/`tasks`, all outside the
whitelist, so `load_domain` fails to load them today. No test in the
repo calls the real (non-Mox) adapter against real domain content, so
this has been silently broken. This port targets the *current* loader
schema, not the stale fixture schema — the fixture/`EntityPlanner`
mismatch is a separate, pre-existing issue.

## Decision Outcome

Unlike ReBAC's split ("search in guest, structural ops via handle
trampoline"), the planner port keeps **everything** — the HTN search
AND all domain evaluation (action bind+body, method bind+check, the
expression language) — in compiled Scheme
(`c_src/s7/fixtures/planner.scm`). The s7 compiler has no floating
point, so the expression evaluator here is deliberately restricted to
what doesn't need it: `eq`/`lt`/`add`/`sub`/`not`/`and`/`or`/`get` over
fixnums, booleans, and atoms — the full KHR_interactivity float/trig/
quaternion/matrix vocabulary is out of scope. The only new host
primitive is `hash-table-set` (op 28): Elixir maps are immutable, so a
functional insert must cross the boundary the same way `hash-table-ref`
already does for reads (`m` may be `#f`, treated as empty, so a
two-level nested-ref/nested-set chain never needs a separate "make an
empty map" primitive).

`Uro.Planner.SandboxAdapter` does nothing but translate parsed domain
JSON into the host-owned tagged lists `planner.scm` walks — no domain
logic lives in Elixir. A 15-element `tags` list of atoms (like ReBAC's
`rel-consts`) carries every structural tag (`call`/`goal`/`multigoal`/
`eval`/`set`/`lit`/`param`/`get`/`eq`/`lt`/`add`/`sub`/`not`/`and`/`or`)
since the reader has no string or symbol literals. Domain names
(actions/methods/vars/keys) and string-valued state are atomized —
safe only because domain JSON is trusted, author-controlled content
(bundled `.jsonld` files), never end-user input.

Search semantics verified faithful to `tw_seek_plan`: `TwGoal` splices
`subtasks ++ (goal) ++ remaining` (re-verifies before `remaining`);
`TwMultiGoal` tries *every* unmet binding, not just the first; compound
`TwCall` splices `subtasks ++ remaining` with no self-re-append. Fuel
spends only on real branching decisions, never on primitive-action or
already-satisfied-goal advancement (mirrors `tw_seek_plan`'s fast
path — confirmed safe via `tw_seek_plan_tree`, the tree-building
sibling that already proves one-task-at-a-time recursion is
semantically identical to the batched fast path). Dropped as pure
performance, not semantics: `fail`/`success`-cache memoization,
method-ordering statistics (start at zero for any single fresh call
anyway), decomposition-signature dedup, the witness-oracle prefix
pruning, the wall-clock budget (the guest's own libriscv instruction
fuel is a structural equivalent DoS guard).

Config-flip, matching RFD66606-0022's exact mechanism: `Uro.Application`
only boots `Uro.Planner.SandboxAdapter.Program` when
`Application.get_env(:uro, :planner_adapter) == Uro.Planner.SandboxAdapter`.

## Consequences

Good: a second, previously-native subsystem now runs entirely as
compiled guest code with no ABI additions beyond one generic map op;
the config-flip costs nothing when unselected. Bad: this stage's
expression language is deliberately narrow (no floats/trig/quaternion/
matrix, no scan methods, no ReBAC-based goal bindings — `goal_satisfied?`
raises rather than silently misinterpreting a `{`-prefixed relation-expr
var) — real domains using those need a later stage (5B/5C, tracked but
not started) or stay on `TaskweftAdapter`.

## Confirmation

`verify_planner` (6 cases: checked-alternative fallback both ways, goal
with no method, multigoal backtracking over 2 bindings, a goal whose
method under-satisfies it forcing 3 retries via the re-append splice, a
50-action flat sequence proving fuel-neutrality) agrees three ways
(hand-written reference oracle == IR interpreter oracle == compiled
RISC-V execution) for all 6.
`test/uro/planner_sandbox_differential_test.exs` runs the same domain
shapes as real JSON through both `TaskweftAdapter` and `SandboxAdapter`,
asserting identical plans or identical no-plan.

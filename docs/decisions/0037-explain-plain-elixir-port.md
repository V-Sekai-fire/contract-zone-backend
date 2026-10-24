---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: taskweft, planner, elixir-port
---

# 0037 `tw_explain.hpp` ported to plain Elixir (native maps, no JSON boundary)

## Context

Continuing the `standalone/` retirement (RFD66606-0026/0028/0029/0030/
0032-0036). `tw_explain.hpp` builds an inspectable explanation tree
for planning outcomes: `tw_solution_tree_value` (for a solved plan,
from a `TwSolTree`) and `tw_no_plan_explain_json` (for a `no_plan`
outcome, from a task list + domain). Depends on `tw_domain.hpp`
(RFD66606-0036, not ported) and `tw_soltree.hpp` (already ported as
`Uro.Planner.SolTree`, RFD66606-0029).

## Decision Outcome

`lib/uro/planner/explain.ex` ports both functions onto
`Uro.Planner.SolTree`, returning plain maps instead of a JSON string —
no language boundary to cross. Tasks are represented as
`{:call, name, args}` / `{:goal, bindings}` / `{:multi_goal, bindings}`
tuples (matching `SolTree.Node`'s own kind atoms), and `domain` is
duck-typed as `%{actions: map_or_set, task_methods: map}` — the same
pattern `Uro.Planner.Replan.task_methods/1` (RFD66606-0030) already
established for "this module doesn't own the domain's real shape."

Unlike `tw_domain.hpp`/`tw_state.hpp` (RFD66606-0036), this file was worth
porting despite depending on a not-yet-ported domain type: its actual
job (converting an already-Elixir `SolTree` into an inspectable map)
is small, self-contained, and immediately useful wherever
`Uro.Planner.SolTree` itself is useful, with no dependency on the
native HTN search's internals — only on two duck-typed queries
(`has_action?`/`has_task?`) any future domain representation can
trivially answer.

## Consequences

Good: `Uro.Planner.SolTree` (RFD66606-0029) now has a matching explain-view
port, so no orphaned "we ported the tree but not the way to look at
it" gap remains. Bad: none identified — every original branch (root/
task/action/goal/multigoal node kinds, resolvable/unresolvable/unknown
symbol classification) is represented.

## Confirmation

`test/uro/planner/explain_test.exs` (9 cases): `node_kind_name/1` for
every kind atom, `call_to_list/1`, `solution_tree_map/2` (full map
shape for a 3-node solved-plan tree, including optional-field
omission for absent name/args), `failure_task_map/3` (resolvable
action, resolvable compound task, unresolvable call, goal, multigoal),
`no_plan_explain_map/2` (full failure-tree assembly).

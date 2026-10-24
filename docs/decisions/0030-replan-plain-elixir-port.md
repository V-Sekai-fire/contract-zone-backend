---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: taskweft, planner, elixir-port
---

# 0030 `tw_replan.hpp` ported to plain Elixir (search injected, not re-derived)

## Context

Continuing "port taskweft to Elixir" (RFD66606-0026/0028/0029), now toward
fully retiring `standalone/`. `tw_replan.hpp` simulates plan execution,
blacklists the exact `(action, args)` command that failed at runtime,
and replans — but its `tw_plan`/`tw_plan_with_tree` calls are the full
HTN search, which today exists only natively or as compiled Scheme
(RFD66606-0023). Re-deriving that search a third time in plain Elixir is
separate, larger work, not this module's job.

## Decision Outcome

`lib/uro/planner/replan.ex` takes the planner as an injected dependency
(`plan_fn`/`plan_with_tree_fn`, matching `tw_plan`/`tw_plan_with_tree`'s
own signatures exactly) rather than re-implementing search. This keeps
`simulate/3`, `replan/5`, `replan_incremental/6` fully testable against
a fake planner — verifying the actual novel content of this module
(simulate-to-failure, blacklist construction, prefix-splicing, ancestor-
based method-skip) independent of search correctness, which is already
covered elsewhere (RFD66606-0023's own differential tests).

## Consequences

Good: a real, reusable seam — once any plain-Elixir planner exists
(should one ever get built), it plugs in directly with no changes to
this module. Bad: not yet an end-to-end integrated feature on its own;
needs a real `plan_fn` to be useful in production, same caveat as
`Uro.Planner.Temporal`'s own "not yet wired to a caller" note.

## Confirmation

`test/uro/planner/replan_test.exs` (10 cases): `simulate/3` (success,
first-failure, unknown action, empty plan), `replan/5` (auto-detected
vs. explicit `fail_step`, exact-command blacklisting, `recovered: false`
on planner failure), `replan_incremental/6` (no-failure short-circuit,
retryable-ancestor prefix-splicing + method-skip construction, fallback
to a full replan when no ancestor is retryable).

---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: taskweft, planner, elixir-port
---

# 0031 `tw_witness_oracle.hpp` intentionally not ported

## Context

Continuing the `standalone/` retirement (RFD66606-0026/0028/0029/0030).
`tw_witness_oracle.hpp` implements a PCG64-seeded, QuickCheck-style
iterative-deepening property search (`Plausible::ForallFin<N>` +
`PlausibleWitnessDag::resolve`) used by `tw_planner.hpp`'s
`tw_seek_plan` fast path (`tw_witness_oracle_goal_reach_cached`,
`tw_planner.hpp:474`) purely to decide whether it's worth continuing to
walk a goal's remaining tasks looking for measurable progress, before
falling back to real search.

## Decision Outcome

Not ported. This is a pure pruning/performance heuristic, not planner
semantics: `tw_seek_plan` is correct without it (it only skips
already-doomed branches sooner), and it's already documented as
"safe to drop" in the earlier Scheme-sandbox planner port (RFD66606-0023's
own scope notes on `planner.scm`) alongside `seen_decompositions`,
`fail_cache`/`success_cache`, and `method_stats` reordering — all four
are randomized/memoized speedups over a search that produces identical
plans without them. Porting a randomized property-testing oracle to
plain Elixir would add real complexity (PCG64 state, iterative-deepening
ladder, `Fin N` sampling) for zero behavioral difference in `replan.ex`
or any other already-ported module — none of them call it.

## Consequences

Good: one less standalone/ file to port, no loss of planning
correctness. Bad: none identified — every caller of this file already
runs the not-yet-built plain-Elixir HTN search (RFD66606-0030's injected
`plan_fn`), which itself doesn't need this heuristic to be correct,
only potentially slower on deeply doomed branches than native code
would be.

## Confirmation

Grepped every reference to `tw_witness_oracle`/`PlausibleWitnessDag`
in the repo: only `tw_planner.hpp` (the fast-path pruning call sites)
and `c_src/taskweft_nif.cpp`/`lib/taskweft/nif.ex` (transitive includes
of the native NIF, not direct callers). No Elixir module outside the
native adapter path depends on this file.

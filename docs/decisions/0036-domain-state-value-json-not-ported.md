---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: taskweft, planner, elixir-port
---

# 0036 `tw_domain.hpp`/`tw_state.hpp`/`tw_value.hpp`/`tw_json.hpp` intentionally not ported

## Context

Continuing the `standalone/` retirement (RFD66606-0026/0028/0029/0030/
0032/0033/0034/0035). These four headers are the foundational types
underneath `tw_planner.hpp`'s native HTN search:

- `tw_value.hpp` — `TwValue`, a recursive tagged-union JSON value
  (nil/bool/int/float/string/array/ordered-dict), plus its JSON
  (de)serialization support.
- `tw_json.hpp` — the JSON parser/serializer operating on `TwValue`.
- `tw_state.hpp` — `TwState`: an ordered-map variable store, a shared
  ReBAC graph pointer for goal-binding satisfaction, and an FNV-1a
  signature hash used for planner memoization.
- `tw_domain.hpp` — `TwCall`/`TwGoal`/`TwMultiGoal`/`TwDomain`: the
  task/goal/method registration types `tw_seek_plan` walks, including
  `TwGoalBinding::satisfied`'s ReBAC-or-equality dispatch.

## Decision Outcome

None of these four get a dedicated plain-Elixir module. Two independent
reasons converge:

1. **`TwValue`/`tw_json.hpp` are already superseded.** Every port so
   far in this series (`Replan`, `MCExecutor`, `Bridge`, `Retriever`)
   already represents "the same data" as ordinary Elixir maps/lists/
   strings, with `Jason` available for any real JSON boundary that
   still exists. A dedicated `TwValue` port would just be reinventing
   `Map`/`List`/`String`/`Jason.decode!` with extra ceremony — there is
   no gap to fill.
2. **`TwState`/`TwDomain` only matter as part of the native HTN search**,
   which is superseded in production by the compiled-Scheme planner
   (RFD66606-0023, `planner.scm`, which represents task/state as host-owned
   tagged lists — not a `TwState`/`TwDomain` port either) and, for the
   plain-Elixir side, is explicitly out of scope per RFD66606-0030's own
   scope note: `Replan`/`MCExecutor` take the search as an *injected*
   `plan_fn`, deliberately not re-deriving `tw_seek_plan` a third time.
   Porting `TwState`'s memoization hash or `TwGoalBinding`'s ReBAC
   dispatch today would be unused code with no caller — a plain-Elixir
   HTN search doesn't exist, and building one is separate, larger,
   not-yet-scoped work.

## Consequences

Good: avoids a mechanical, purposeless translation of C++ struct
layouts (ordered-map iteration order, FNV-1a hashing, shared_ptr
refcounting) that plain Elixir wouldn't represent the same way even if
ported. Bad: if a plain-Elixir HTN search is ever built, `TwState`'s
goal-satisfaction logic (`TwGoalBinding::satisfied`, RFD66606-0023's own
already-documented ReBAC-vs-equality dispatch) will need porting at
that time — but as part of that search's own design, the same way
`planner.scm` designed its own state/task representation rather than
porting `TwState`/`TwDomain` line-for-line.

## Confirmation

No test suite — this is a decision not to write code. Confirmed by
reading all four headers in full and cross-referencing every other
already-completed port in this series to verify none of them actually
needs a `TwValue`/`TwState`/`TwDomain` equivalent that isn't already
covered by native Elixir data structures or RFD66606-0023's Scheme-side
task/state representation.

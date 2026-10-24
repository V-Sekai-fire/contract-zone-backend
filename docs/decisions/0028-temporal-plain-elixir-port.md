---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: taskweft, temporal, elixir-port
---

# 0028 `tw_temporal.hpp` ported to plain Elixir

## Context

Continuing the "port taskweft to Elixir, slowly, one piece at a time"
direction (following RFD66606-0026/0027's loot-core pivot): `standalone/
tw_temporal.hpp` (ISO 8601 duration parsing, a Floyd-Warshall Simple
Temporal Network consistency check, civil-calendar `Y`/`Mo`
arithmetic) is reachable from real NIF entry points
(`check_temporal`/`plan_with_temporal[_civil][_explain]`) and, per this
session's earlier survey, is self-contained arithmetic/parsing logic —
not untrusted content, the same reasoning that moved loot-core off the
sandbox.

## Decision Outcome

`lib/uro/planner/temporal.ex`. One real simplification found while
porting: the original STN used `double` distances and `infinity()`
purely as a "no constraint yet" sentinel — every actual constraint fed
to it is an integer millisecond duration. Ported entirely in integer
milliseconds with a large sentinel (`10^12` ms, ~34,000 years) instead
of true infinity, dropping the original's `dur_s = dur_ms / 1000.0`
round-trip — this module needs no floating point at all. Civil-calendar
arithmetic uses Elixir's stdlib `Date` plus Erlang's
`:calendar.last_day_of_the_month/2` for day-clamping (e.g. Jan 31 + 1
month -> Feb 28/29) — no date library dependency, unlike the original's
vendored Howard Hinnant `date.h`.

## Consequences

Good: no floats, no external date library, same trust-appropriate
"plain Elixir, not sandboxed" pattern as `Uro.LoopCore`. Bad: not yet
wired to a real caller (no `Uro.Ports.Planner`-style adapter exists for
temporal checking today) — this lands as a tested, ready-to-use module,
not yet an integrated feature; wiring it up is separate follow-on work.

## Confirmation

`test/uro/planner/temporal_test.exs` (21 cases): duration parsing
(canonical order, week-standalone rule, fraction-only-on-last-unit,
malformed input), formatting round-trips, sequential STN checks
(empty plan, multi-step accumulation, origin offset), and civil-
calendar arithmetic (Jan 31 + 1 month clamps to Feb 29 in a leap year;
P1Y from a leap-year date counts 366 days; `check_civil/4` matches
`check/3` exactly with no reference date).

---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: taskweft, planner, elixir-port
---

# 0035 `tw_bridge.hpp` ported to plain Elixir (edges as data, no graph handle)

## Context

Continuing the `standalone/` retirement (RFD66606-0026/0028/0029/0030/
0032/0033/0034). `tw_bridge.hpp` is plan-memory bridge glue:
`parse_relation_edges` (regex-extract relation sentences from stored
facts into a ReBAC graph), `extract_state_entities`/
`state_bindings_contents` (turn planner state into storable memory
facts), `plan_result_contents` (turn a finished plan into storable
memory facts). Mostly string-formatting + one regex + a trust gate —
the "near-no-op port" predicted when this file was first surveyed.

## Decision Outcome

`lib/uro/planner/bridge.ex` ports all four functions directly onto
plain Elixir data (facts/plan/state/entities as maps/lists/strings, no
JSON string boundary). `parse_relation_edges/2` does NOT construct a
`Uro.ReBAC` graph handle itself — `Uro.ReBAC.new_graph/0` returns an
opaque handle (native NIF resource or sandbox program handle,
RFD66606-0018/0022) that this module has no way to introspect or safely
construct outside the real adapter. It returns plain
`{subject, relation, object}` triples instead; a caller wanting a real
graph folds `Uro.ReBAC.add_edge/4` over the result.

One quirk from the original is preserved exactly, not fixed:
`relation_keywords/0` is keyed by the *first word* of the matched verb
phrase. Two of the eight recognized verb phrases —
`"has capability"` (first word `"has"`) and `"is member of"` (first
word `"is"`) — have their real keyword (`"capability"`/`"member"`) in
a later word, so they never actually match anything and are silently
dropped. This reads as a pre-existing bug in the C++/Python original,
not something to silently correct mid-port.

## Consequences

Good: no JSON encode/decode, no dependency on an opaque ReBAC graph
type this module shouldn't own. Bad: none identified — every original
function's observable behavior (including the first-word quirk) is
preserved.

## Confirmation

`test/uro/planner/bridge_test.exs` (12 cases): `binding_content/3`;
`parse_relation_edges/2` (simple/multiple relation extraction,
trust-threshold gating including "no `trust_score` field present" pass-
through, the preserved first-word quirk, no-match content); 
`extract_state_entities/1` (private/internal/rigid var skipping,
rigid-prefixed arg skipping); `plan_result_contents/3` (summary +
per-step facts, 5-entity/20-step caps); `state_bindings_contents/3`
(one fact per triple, rigid args NOT skipped here — matching the
original's asymmetry with `extract_state_entities/1`).

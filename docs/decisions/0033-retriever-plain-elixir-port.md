---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: taskweft, elixir-port
---

# 0033 `tw_retriever.hpp` ported to plain Elixir (native data, no JSON boundary)

## Context

Continuing the `standalone/` retirement (RFD66606-0026/0028/0029/0030/0032).
`tw_retriever.hpp` implements hybrid keyword/HRR retrieval scoring —
`score_candidates` (FTS-rank + Jaccard + HRR-similarity blend, weighted
by trust and temporal decay), `probe_score` (exact algebraic
content-from-binding extraction), and `reason_score` (AND-semantics
minimum similarity across multiple entity vectors). It depends only on
`tw_hrr.hpp` (already ported, RFD66606-0032) plus a JSON parse/serialize
round-trip that existed solely to cross the native NIF boundary.

## Decision Outcome

`lib/uro/planner/retriever.ex` ports the three scoring functions
directly onto `Uro.Planner.HRR`. The JSON string in/string out
signature is dropped: candidates are plain lists of string-keyed maps
(the shape `Jason.decode!/1` already produces), since nothing crosses a
language boundary anymore — round-tripping through JSON text inside a
single BEAM process would be pure overhead with no purpose.

## Consequences

Good: no JSON encode/decode step, no `TwValue`/`TwJson` intermediate
representation needed — this repo's ordinary Elixir maps/lists already
are the working data structure. Bad: none identified; every original
function is behaviorally represented (weighted blend, trust/decay
multiplication, stable descending sort, output-field stripping).

## Confirmation

`test/uro/planner/retriever_test.exs` (11 cases): `tokenize/1`
(lowercase/split/punctuation-strip/dedupe), `jaccard/2` (empty-set
zero case, intersection-over-union), `temporal_decay/2` (disabled/
negative-age passthrough, one-half-life midpoint), `score_candidates/7`
(ranks a matching candidate above an unrelated one, strips
`hrr_vector`, default trust/fts_rank), `probe_score/3` (high similarity
for a correctly-encoded binding, neutral 0.5 default, strips
`binding_vector`), `reason_score/3` (empty entity list short-circuits,
minimum-across-entities semantics).

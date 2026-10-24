---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: taskweft, elixir-port
---

# 0032 `tw_hrr.hpp` ported to plain Elixir (SHA-256/float64 handled natively)

## Context

Continuing the `standalone/` retirement (RFD66606-0026/0028/0029/0030/0031).
`tw_hrr.hpp` implements Holographic Reduced Representations (Plate 1995
/ Gayler 2004): deterministic SHA-256-derived phase vectors for atoms,
circular-convolution `bind`/`unbind`, circular-mean `bundle`, cosine
`similarity`, plus text tokenization/encoding and float64 (de)serialization.
It's real-valued and self-contained — no untrusted content, matching the
category already established for `Temporal`/`SolTree`/`Replan`.

## Decision Outcome

`lib/uro/planner/hrr.ex` ports the algebra directly. Two of the original's
own hand-rolled sections collapse entirely rather than porting line-for-line:

- **SHA-256** (`_sha256` namespace, ~90 lines of FIPS 180-4 by hand):
  replaced with the BEAM's native `:crypto.hash(:sha256, ...)`. Both are
  pinned to the same public standard, so this is a zero-fidelity-risk
  simplification, not a behavior change.
- **float64 (de)serialization** (`phases_to_bytes`/`bytes_to_phases`):
  replaced with Elixir's native binary pattern-matching
  (`<<phase::float-little-64>>`), which already implements IEEE 754
  little-endian float64 packing — no hand-rolled byte-shuffling needed.

Everything else (atom phase derivation from little-endian uint16 pairs,
circular convolution/correlation, circular-mean bundling via
`atan2(sum sin, sum cos)`, cosine similarity, tokenization, text/binding/
fact encoding) is a direct structural port.

## Consequences

Good: ~90 lines of hand-rolled cryptographic and byte-packing code disappear
with no fidelity loss, since both delegate to the same underlying standards
the original targeted. Bad: no golden byte-vector from the original Python/
C++ implementations is vendored in this repo to diff against directly — the
port is verified against the algebra's own defining properties instead (see
Confirmation). If exact cross-language byte-identical vectors are ever
needed (e.g. comparing against a live Python `holographic.py` process),
that would need a small fixture generated from the Python side, out of
scope here.

## Confirmation

`test/uro/planner/hrr_test.exs` (16 cases): `encode_atom/2` determinism/
dimension/phase-range; `bind/2`+`unbind/2` inverse property; `bundle/1`
empty-input and self-similarity; `similarity/2` empty-vector and self-
similarity; a bundled component being meaningfully closer to its bundle
than an unrelated atom is; `snr_estimate/2`; `tokenize/1` lowercase/
whitespace-split/punctuation-stripping; `encode_text/2` empty-string and
floating-point-tolerant order-independence; `encode_binding/3`'s defining
`unbind(encode_binding(c, e), encode_atom(e)) == encode_text(c)` identity;
`phases_to_bytes/1`/`bytes_to_phases/1` round-trip and byte-count.

---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: taskweft, planner, elixir-port
---

# 0034 `tw_mc_executor.hpp` ported to plain Elixir (injected actions, native RNG)

## Context

Continuing the `standalone/` retirement (RFD66606-0026/0028/0029/0030/0032/0033).
`tw_mc_executor.hpp` is a Monte Carlo plan executor: it draws one
uniform(0,1) sample per plan step, compares against that step's
success probability, applies the domain action if drawn successful,
and stops at the first failure — a stochastic "what if this step
doesn't go as planned" simulator, not verified game logic.

## Decision Outcome

`lib/uro/planner/mc_executor.ex` takes domain actions as an injected
`%{name => (state, args -> state | nil)}` map, exactly matching
`Uro.Planner.Replan`'s own `action_fn` contract (RFD66606-0030) — for the
same reason: domain loading is `Uro.Planner.TaskweftAdapter`/
`Uro.Planner.SandboxAdapter`'s job, not this module's. State is a
plain map throughout (no JSON string round-trip, since nothing crosses
a language boundary anymore).

The RNG is Erlang's built-in `:rand` (`exsss` algorithm via
`:rand.seed_s/2` + `:rand.uniform_s/1`), not a hand-rolled
`std::mt19937_64`. This is a deliberate, documented non-goal of
bit-identical draws against the C++ oracle: the C++ port itself
already diverges from the upstream Python `mc_executor.py` (CPython's
`random` module uses 32-bit Mersenne Twister internals, distinct from
`std::mt19937_64`), so "byte-identical across all three languages" was
never actually true even before this port. What callers need —
same seed producing the same outcome sequence within one Elixir
process — `:rand.seed_s/2` provides directly.

One behavioral quirk is preserved exactly: if a step's draw is a
success but the action name isn't in the injected `actions` map, the
step is still recorded as succeeded with state left unchanged (the
original C++ has no `else` branch on a failed action lookup — this
reads as latent, not intentional, but changing it would be a silent
behavior change, not a faithful port).

## Consequences

Good: reuses the same dependency-injection seam RFD66606-0030 already
established, so the same eventual plain-Elixir planner (should one get
built) plugs into both modules identically. Bad: not bit-identical to
the native NIF's random draws — acceptable since Monte Carlo simulation
output was never meant to be exactly reproducible across the
Python/C++/Elixir chain to begin with, only internally deterministic
per seed.

## Confirmation

`test/uro/planner/mc_executor_test.exs` (6 cases): probability-1.0
always-succeeds edge, default-probability-1.0 when `probs` is omitted,
probability-0.0 always-fails-immediately edge, an action returning
`nil` recorded as a failure that halts the plan, an unknown action
name with a drawn success staying recorded as succeeded with state
unchanged (the preserved quirk), and same-seed-same-outcome
determinism.

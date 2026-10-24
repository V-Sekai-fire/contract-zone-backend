---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: loot-loop, loop-core, actors
---

# 0027 `Uro.LoopCore.Instance`: one actor per Field instance

## Context

RFD66606-0026's plain-Elixir `LootCore`/`CombatCore`/`ProgressionCore` need a
caller that holds live per-session state. Real-time combat/loot event
routing belongs to `zone-server` (a separate repo) —
`lib/uro/channels/zone_channel.ex` is zone metadata/heartbeat only, not
gameplay — so this stays a reusable, testable actor zone-backend owns
directly, not a new WebSocket surface.

## Decision Outcome

`Uro.LoopCore.Instance`: one GenServer per active Field instance (not
per entity), holding that instance's `CombatCore.State` and
`ProgressionCore.Profile`, exposing `combat_step/2`, `loot_roll/3`,
`progression_step/2` with real per-call arguments. Since this logic is
fully-trusted (RFD66606-0026), "pause"/"resume"/"gas"/"sandbox" reduce to
what a GenServer already gives for free: idle between calls is pause,
the next call is resume, an ordinary call timeout is the gas budget,
BEAM's per-process isolation is the sandbox. `WeftWarpBurrito.Program`'s
trampoline-based pause/resume/gas remains the right tool for genuinely
untrusted content (ReBAC graphs, planner domains) — this module doesn't
need or imitate that machinery.

## Consequences

A real, parameterized, stateful entry point exists for combat-loop
content with zero new infrastructure. Per-entity actors/message-passing
are deferred until something actually needs cross-instance
coordination — not invented speculatively.

## Confirmation

`test/uro/loop_core_test.exs` drives each of the three calls through
`Uro.LoopCore.Instance` with real (non-golden) scenarios, confirming
state persists correctly across calls within one instance.

---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A — committed directly, no PR review
labels: loot-loop, loop-core
---

# 0026 Loot/combat/progression cores ported to plain Elixir

## Context

RFD66606-0020's Confirmation bar: "at least one slice behavior... executes
from an s7-compiled/sandboxed script through zone-backend's
trampoline." Investigation found this nearly already met on the
*interpreted* side: `c_src/guest/content/{loot,combat,progression}.scm`
are complete, correct, Lean-verified reducers (hand-ported line-for-line
from `v-sekai-multiplayer-fabric/{loot,combat,progression}`, golden-
vector-proven), but exposed only through fixed, argument-less replay
wrappers (`c_src/guest/weft_guest.c`).

This RFD's first draft planned to instead AOT-compile these three
files through `c_src/s7/` (adding bitwise primitives, `cond`, and named
`let` to close the feature gap — RFD66606-0024/0025, both still landed as
general compiler improvements, useful independent of this decision).
**That plan was superseded before shipping.** The RISC-V sandbox exists
for a specific trust boundary — untrusted or externally-influenced
content (ReBAC graphs, planner domains, RFD66606-0021/0022/0023) — that
doesn't apply to combat/loot/progression: this is fully-trusted,
team-authored game logic, already verified upstream in Lean. Running
it through a RISC-V emulator adds sandbox machinery with no matching
threat to sandbox against, and slows the edit-iterate loop the RISC-V
AOT compiler itself was built to speed up (RFD66606-0019).

## Decision Outcome

Port the three files to plain, idiomatic Elixir
(`lib/uro/loop_core/{loot_core,combat_core,progression_core}.ex`) —
not compiled, not sandboxed. `record-macros.scm`'s `define-record`/
`record-with` macros are replaced natively by Elixir struct syntax
(`%State{s | hp: 0}`); no macro library needed. Fastest possible
iteration: no reader, no compiler, no VM — just Elixir source, same
trust level as any other module in this app.

## Consequences

Good: real gameplay logic runs natively, real per-call parameterization
(not fixed golden replays) via `Uro.LoopCore.Instance` (RFD66606-0027);
zero new infrastructure. Bad: this logic is no longer sandboxed —
correct, since it was never untrusted content, but a future port of
genuinely external/adversarial game content should NOT default to this
pattern; it should go through the RISC-V sandbox the way ReBAC/Planner
do.

## Confirmation

`test/uro/loop_core_test.exs` matches the three pre-existing golden
values exactly (`loot-roll(42,...)=3`; combat `tick=30,hp=90,alive`;
progression `credits=150,affinity=16`) plus real-parameterization cases
(a different loot table, a full combat exchange past the invuln
window, a gated `buyArt` refusal) proving `Uro.LoopCore.Instance`
isn't limited to replaying the golden vectors.

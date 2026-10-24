---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: discussion
discussion: N/A -- not yet reviewed
labels: sandbox, godot, determinism, lockstep
---

# 0040 Should zone-backend adopt the godot-sandbox guest API surface, and does `lib_godot_connector` belong here?

## Context

This RFD is ideation-stage, written to capture and scope a request before
any implementation, following [Oxide Computer Company's RFD
process](https://rfd.shared.oxide.computer/rfd/0001) -- record the
question and the options honestly, even (especially) when the answer
isn't decided yet, rather than let it live only in chat history or a
scratch `todo.md`.

The request names four external resources. Each was actually read
(not assumed) before writing this:

1. **`extension_api-4-7-single-precision.json` /
   `extension_api-4-7-double-precision.json`** -- Godot 4.7's full
   GDExtension API descriptor (every class/method/enum/signal Godot
   exposes to native extensions), one JSON file per float-precision
   build. These live in `taskweft/godotweft` (item 3 below): the
   single-precision file is pulled directly from `godotengine/godot-cpp`
   master; the double-precision file is a documented placeholder --
   its `README.md` explains it must be produced by building Godot 4.7
   with `scons precision=double` and dumping the API, not by cloning.
2. **`fabric-godot-core`'s `feat/sandbox/modules/sandbox/program/cpp/api`**
   -- the godot-sandbox project's guest-side C++ API surface (this
   org's fork/branch of `libriscv/godot-sandbox`): headers/sources for
   `Variant`, `Array`, `Dictionary`, `String`, `Node`/`Node2D`/`Node3D`,
   `Vector2/3/4`, `Basis`, `Quaternion`, `Transform2D/3D`, `Rect2`,
   `Rect2i`, `Plane`, `RID`, `Callable`, `Timer`, `CanvasItem`, plus
   `syscalls.h`/`syscalls_fwd.hpp` (the ecall numbering a guest program
   links against) and `api.cpp`/`api.hpp`/`api_inline.hpp`/`native.cpp`
   (the glue). This is the real, much richer sibling of the tiny
   tagged-GuestValue ABI `WeftWarpBurrito.Program` speaks (RFD66606-0018) --
   it lets a RISC-V guest program manipulate live Godot scene-tree
   objects, not just fixnums/atoms/lists/maps.
3. **`taskweft/godotweft`** (private) -- "Taskweft extern taxonomy for
   the Godot 4.x GDExtension API": a Lean4 formalization of the
   GDExtension API's known methods (organized into
   `Core_1..8`/`Editor`/`Node`/`Object`/`Properties_1..3`/`Resource`/
   `Server_1..2`/`Signals`/`Utility`/`Builtin` -- one Lean file per
   category), the two `extension_api-4-7-*.json` files above, two
   JSON-LD files (`godot-sandbox-elf.jsonld`, `planweft-riscv-asm.jsonld`
   -- domain/context vocabularies, evidently for describing sandboxed
   ELF programs and RISC-V assembly in the same RDF-ish style this
   repo's own `capabilities`/ReBAC graph JSON already uses) and one
   patch, `bigassm-sandbox.patch`, which adapts a separate RISC-V
   assembler project ("bigassm") to run *as a godot-sandbox guest ELF
   itself* -- replacing its CLI entry point with the `api.hpp` vmcall
   surface from item 2, and writing its output ELF to an in-memory
   buffer instead of a file. This is prior art for "a real, nontrivial
   guest program built against the godot-sandbox API," not taxonomy
   alone.
4. **`lib_godot_connector`** (hex.pm, v4.5.1, author `ddaian`,
   `github.com/Ughuuu/libgodot`) -- an unrelated, proof-of-concept
   package: "Elixir connector for LibGodot via NIFs." **This solves a
   different problem than items 2-3.** LibGodot embeds the actual
   Godot *engine* as a linkable library, callable from a host process
   (BEAM, here) -- there is no RISC-V sandbox, no guest/host ecall
   boundary; it's direct, unsandboxed, in-process engine access, aimed
   at a process that wants to *run* Godot. godot-sandbox (items 2-3) is
   the opposite shape: a RISC-V guest program, sandboxed and gas-
   metered, calling back into a *separate* host process (the actual
   game/editor) through a narrow ecall surface. `WeftWarpBurrito.Program`
   (RFD66606-0018/0039) is built for the godot-sandbox shape, not the
   LibGodot shape.

**Immediately relevant, from this same session**: RFD66606-0039 just retired
`WeftWarpBurrito.Sandbox` (the fixed-capability
`:loot_roll`/`:combat_replay`/`:progression_replay` guest, `c_src/guest/`,
and the vendored `c_src/thirdparty/s7` interpreter it embedded) as dead
code, and `Uro.ReBAC.SandboxAdapter`/`Uro.Planner.SandboxAdapter` as
plain-Elixir ports -- both because their content was trusted, bundled,
non-adversarial, so a RISC-V sandbox added machinery with no matching
threat to contain. `WeftWarpBurrito.Program` (the generic tagged-
GuestValue trampoline) was kept specifically for "a future genuinely-
untrusted-content guest program." **This request may be exactly that
future case arriving** -- or it may not be; that's the open question
this RFD exists to name rather than assume.

## Question 1, answered: bit-exact client/server lockstep execution

The driving use case: **the server must execute the same simulation
logic the Godot client executes and get bit-for-bit identical results**
-- deterministic lockstep, where zone-backend is not a passive observer
of client-reported state but an independent, authoritative re-executor
of it. This rules in and rules out several things at once:

- **Not (a) "CI/tooling validation only."** The server needs to
  actually *run* the guest program's logic at request time (during
  live play), not just lint it ahead of time.
- **Not quite (b) either.** The point isn't "server produces an ELF for
  the client to run" -- it's that **the same ELF** (however it's
  produced) needs to execute identically wherever it runs, client or
  server. Whichever side compiles it, both sides load and run the exact
  same guest program.
- **This is exactly the shape `WeftWarpBurrito.Program` already
  provides -- and exactly why RFD66606-0039 kept it.** A fixed RISC-V ISA
  interpreted by libriscv is a single, reproducible execution substrate
  *regardless of the host CPU* running the interpreter. That's the
  whole reason this is more promising than it looks at first glance:
  ordinary cross-platform floating point (x86 vs. ARM, different libm
  versions, different compiler codegen) is famously **not**
  bit-reproducible, which is precisely the problem lockstep networking
  needs solved. Executing the identical guest ELF through the identical
  interpreter on both ends sidesteps that problem entirely, as long as
  the *host-call trampoline* (RFD66606-0018) doesn't reintroduce
  non-determinism of its own.

This directly answers Question 2 as well, more strongly than the
original framing: **`lib_godot_connector` is actively the wrong tool for
this goal**, not just a mismatched shape. It embeds the real Godot
engine natively per-host -- exactly the "different CPU, different libm,
different codegen" non-determinism a lockstep design must avoid. The
RISC-V-sandboxed guest-execution shape isn't merely a stylistic fit
here; it's the one property (bit-identical execution regardless of host
platform) that makes this problem tractable at all.

## The real open technical question this surfaces

`WeftWarpBurrito.Program`'s tagged-GuestValue ABI (`lib/weft_warp_burrito/
program.ex`, `c_src/nif/weft_sandbox_nif.cpp`) **has no floating-point
support today** -- confirmed by grep, zero hits for `float`/`Float` in
either file. Every godot-sandbox API type in item 2
(`Vector2/3/4`, `Basis`, `Quaternion`, `Transform2D/3D`, `Rect2`, `Plane`)
is float-based; `Variant` itself carries floats as one of its core
scalar kinds. RFD66606-0018's original design notes always described a
`Float64` GuestValue variant as part of the plan, but -- confirmed by
reading the actual retired `c_src/s7/value.h` history and the current
`program.ex` -- it was never implemented, because neither prior
consumer (ReBAC graphs, planner domains, both RFD66606-0039) needed floats.
**This is the actual unresolved design question a follow-on RFD needs
to own**: not "should GuestValue support floats" (yes, self-evidently,
for this use case) but "how is float *determinism* itself guaranteed" --
IEEE 754 arithmetic is bit-reproducible only when both sides commit to
the same rounding mode, the same operation ordering, and no fused-
multiply-add-style codegen differences sneak in through the RISC-V
compiler backend used to produce the guest ELF in the first place.
This is squarely where `taskweft/godotweft`'s Lean taxonomy (item 3)
plausibly becomes load-bearing rather than reference-only: a formal
description of exactly which GDExtension operations are safe to treat
as deterministic primitives is a natural artifact to check the eventual
implementation against.

## Guest-program language is a separate, still-open choice

The sandbox contract is "compiles to a RISC-V ELF that libriscv can
execute" -- nothing about that contract mandates a source language.
Item 2's reference API surface happens to be C++ because that's what
upstream `libriscv/godot-sandbox` guest programs are conventionally
written in, but this org already retired one purpose-built guest
language this same session (RFD66606-0039: the s7-Scheme subset compiler,
`c_src/s7`), specifically because it was never worth the machinery for
its actual callers. Picking a guest language for *this* use case is
worth doing deliberately rather than defaulting to "whatever the
reference implementation uses" -- **and the criterion is narrower than
generic memory safety**: this guest program (unlike RFD66606-0039's retired
ReBAC/planner content) processes input an active adversary controls.
Even dev-authored, trusted simulation *logic* still needs to survive a
malicious client crafting inputs specifically to trigger memory-safety
or UB bugs in that logic -- libriscv's own sandbox (gas metering,
memory bounds) contains the *blast radius* of such a bug, but doesn't
prevent the bug from existing or from being a real, exploitable
divergence-inducing (or crashing) path in the first place. That's a
materially different bar than "pick whatever's convenient":

- **C/C++**: matches item 2 directly -- zero translation friction to
  vendor and call its API surface as-is. Weakest safety guarantee
  against exactly this threat model of the candidates: memory-safety
  bugs (UB, uninitialized reads, overflow) are this language's most
  common attacker-facing surface, and cross-platform floating-point
  non-determinism (see above) is a second, independent hazard
  (implicit promotions, easy-to-miss `-ffast-math`/FMA-contraction
  compiler flags).
- **Rust**: has a mature `riscv64gc-unknown-none-elf`/Linux target.
  Its safe subset rules out the memory-safety half of the threat model
  by construction (no UB from a crafted input triggering a bounds/
  aliasing violation in safe code); `fp-contract` behavior is at least
  explicit and auditable rather than implicit.
- **Lean4**: matches this org's own existing verification-first
  tooling directly -- `taskweft/godotweft`'s Lean `KnownMethods`
  taxonomy, `fire/plausible-witness-dag` (below), and RFD66606-0026's own
  precedent of Lean-verified reducers for loot/combat/progression, all
  already exist. A formally verified guest program is the strongest
  answer to "safe against active attack" available in principle (a
  proven absence of a whole bug class beats "no one's found one yet"),
  but whether Lean4's compiled output (it compiles to C, then native
  code) can plausibly run as a *freestanding* libriscv guest at all --
  no OS, no libc assumptions the runtime doesn't already make explicit
  -- is a genuine, unverified technical question. It has never been
  tried by any resource this RFD references.
- **Formal methods more generally, on top of any of the above**: the
  language choice and the verification-rigor choice are actually two
  separate axes, not one -- a Lean4-*specified* determinism/safety
  property could in principle be discharged against a C, Rust, *or*
  Lean4 implementation (e.g. via a verified compiler pipeline, or a
  reference-vs-implementation equivalence proof), not only by writing
  the guest program in Lean4 itself. Which combination is worth the
  effort is exactly the kind of question a follow-on RFD should answer
  with a concrete threat model in hand, not this one.

No candidate is picked here. This is recorded as its own open question,
separate from the ABI/API-surface question above, with the threat model
now stated explicitly (safety against a crafted-input active attacker,
not just "safer by default") -- the follow-on RFD should make this
choice against that stated bar rather than let a default win by
omission.

## Verification tooling: `fire/plausible-witness-dag`

Directly relevant to the float-determinism question above, and worth
recording now while it's fresh: this org already owns
`fire/plausible-witness-dag`, a small Lean/Lake library (factored out of
Flowref) for **plausible-driven iterative-deepening witness search** --
domain code supplies a deterministic walk function and a candidate
predicate over `Fin`-bounded random candidates (via
`leanprover-community/plausible`, the Lean4 QuickCheck-style property
tester -- the Lean-ecosystem sibling of Elixir's PropCheck/StreamData,
matching this session's own already-stated PropCheck-over-StreamData
preference), and `resolve` climbs a ladder of increasing search budgets
("levels": `walkSteps`/`finBound`/`numInst`) until a witness is found or
budgets are exhausted (confirmed by reading its actual
`PlausibleWitnessDag/Examples.lean`, a 3-/5-gallon water-jug puzzle
solved this way -- not assumed from the README alone).

This is a plausible, concrete fit for certifying (not formally proving)
that a specific godot-sandbox math primitive is deterministic: define
the primitive's Lean4 model as the deterministic walk, a candidate
predicate that flags any input where two independently-computed
results diverge, and let `plausible-witness-dag` search increasingly
large `Fin`-bounded input spaces for a counterexample. Finding none
within a budget is evidence, not proof -- exactly the same honest
caveat property-based testing always carries, and consistent with this
tool's own name ("plausible," not "certain"). Whether this is the right
level of rigor for lockstep-critical code (vs. an actual Lean4 proof of
the determinism property) is itself part of the follow-on RFD's job,
not decided here.

## Non-decision

No implementation decision is made here -- Question 1 has a clear
answer now, but the "how" (GuestValue float support, the determinism
contract across the host-call trampoline, which subset of the
godot-sandbox API surface a lockstep guest program actually needs vs.
the scene-tree-only calls like `Node`/`CanvasItem`/`Timer` that don't
mean anything without a live tree, which guest language to write it in,
and whether/how `plausible-witness-dag`-style certification factors in)
is real, non-trivial design work this RFD doesn't attempt to resolve
inline. A follow-on RFD should cover the concrete design once scoped.

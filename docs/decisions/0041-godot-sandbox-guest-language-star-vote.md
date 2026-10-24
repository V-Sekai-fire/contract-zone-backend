---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: discussion
discussion: N/A -- not yet reviewed
labels: sandbox, godot, determinism, lockstep, language-choice
---

# 0041 Godot-sandbox guest-program language: C/C++ to execute, Lean4 to verify

## Context

RFD66606-0040 named the guest-program language as its own open question,
separate from the ABI/API-surface question, and stated the real
criterion explicitly: **safety against an active attacker who controls
the guest program's input**, not "safer by default" in the abstract.
This RFD picks up that thread specifically, scoring the candidates
RFD66606-0040 already named (C/C++, Rust, Lean4) against that bar and the other
axes RFD66606-0040 raised, using a STAR-voting-style scoring round plus an
automatic runoff -- Olympic-style multi-judge scoring (several
independent criteria, each scored like a judge) feeding a transparent,
reproducible ranking method, rather than an unranked bullet list or a
single unstated gut call.

**The scoring round below produces a tie between C/C++ and Lean4 --
but that tie turns out to be an artifact of scoring Lean4 in the wrong
category, not a genuine draw.** Lean4 is a proof verifier, not an
execution language: it was never actually a candidate to replace C/C++
as the thing that compiles to the freestanding guest ELF. Once that's
corrected (see "Category correction" below), and a later Ada/SPARK
addition is scored against the same rubric, this RFD's mechanical STAR
method points to **C/C++ as the execution language** (the highest-
scoring eligible candidate once Rust/Zig are blocklisted and Lean4 is
moved to its correct category) -- **though a genuine, flagged judgment
call remains open between C/C++ and Ada/SPARK** (see "A fifth
candidate" below), since Ada/SPARK wins on the two axes RFD66606-0040 named
as primary even though it loses the mechanical runoff on judge count.
Either way, **Lean4 is used as a verification layer on top**,
most immediately via differential testing against a Lean4-extracted
oracle -- the same pattern RFD66606-0026 already used successfully.

**Org policy update, applied after the vote below was run**: Rust and
Zig are blocklisted for this use case as not mature enough -- a
standing policy call, not a per-criterion score. The scoring table
below keeps both (the work of scoring them stands, and shows *why*
they'd have been strong candidates on a pure-merits basis: Rust nearly
tied the leaders even after the literature search below raised its
toolchain-maturity score), but **the runoff that actually matters is
between C/C++ and Lean4 -- the only two eligible candidates** -- which,
convenient or not, is exactly the pair already tied for first. The
blocklist doesn't change this RFD's central conclusion; if anything it
sharpens it, since the two blocklisted candidates were never live
options regardless of their scores.

## Method

**STAR** (Score Then Automatic Runoff): every judge scores every
candidate 0-5. Scores are summed; the two highest-scoring candidates go
to an automatic runoff, where each judge's preference is whichever of
the two finalists it scored higher (a tie on that judge casts no
preference). Whichever finalist wins more judges' preference wins the
runoff.

**Judges** (five criteria, each scoring 0-5, grounded directly in what
RFD66606-0040 already established -- none invented fresh for this vote):

1. **Safety against active attack** -- RFD66606-0040's stated primary bar:
   this guest program processes attacker-controlled input, so this
   judge weighs memory/type safety against a crafted-input adversary
   specifically, not general code quality.
2. **Determinism / float-reproducibility** -- how auditable and
   controllable the language's floating-point semantics are (rounding,
   FMA contraction, implicit promotion), since bit-exact lockstep is
   RFD66606-0040's entire driving use case.
3. **RISC-V/libriscv toolchain maturity** -- how proven (vs. merely
   plausible) it is that this language can produce a freestanding
   guest ELF libriscv can execute today.
4. **Fit with existing org tooling/investment** -- `taskweft/godotweft`
   (Lean `KnownMethods` taxonomy), `fire/plausible-witness-dag`, and
   RFD66606-0026's Lean-verified reducers are real, already-owned assets; this
   judge scores how directly a candidate builds on them vs. starting
   from zero.
5. **Translation friction from the reference API surface** -- item 2 of
   RFD66606-0040 (`fabric-godot-core`'s `modules/sandbox/program/cpp/api`) is
   C++; this judge scores how much rewriting a candidate requires to
   actually call that surface (or a from-scratch equivalent).

## Scoring round

| Judge | C/C++ | Rust | Lean4 | Zig | Ada/SPARK |
|---|---|---|---|---|---|
| 1. Safety vs. active attack | 1 | 4 | 5 | 2 | 5 |
| 2. Determinism / float-reproducibility | 2 | 3 | 3 | 2 | 4 |
| 3. RISC-V/libriscv toolchain maturity | 5 | 4 | 1 | 3 | 4 |
| 4. Fit with existing org tooling | 2 | 1 | 5 | 1 | 1 |
| 5. Translation friction (lower rewrite cost scores higher) | 5 | 2 | 1 | 3 | 3 |
| **Total** | **15** | **14** | **15** | **11** | **17** |

(Rust's toolchain-maturity cell and the new Zig column are revised
from a literature search performed after the first scoring pass --
see "Literature search" below for what changed and why. Zig joins as
a fourth candidate rather than a footnote because it's the only
addition from that search with enough evidence to score on all five
judges; it doesn't change the runoff outcome.)

Rationale per cell, so these numbers are checkable rather than
asserted:

- **C/C++** scores lowest on safety (1) -- RFD66606-0040 named this
  explicitly as the weakest candidate against the stated threat model.
  It scores highest on toolchain maturity (5) and translation friction
  (5) for the same reason: it *is* the reference implementation's
  language, so there is zero unproven risk and zero rewrite cost.
  Determinism (2) and org-tooling fit (2) are both weak: floating-point
  hazards are easy to introduce by accident, and this path doesn't draw
  on any of this org's Lean-based verification investment.
- **Rust** is the "safe middle": strong on safety (4 -- its safe
  subset rules out memory-safety violations by construction, though
  unsafe blocks at the guest-runtime boundary keep it just short of 5)
  and a genuine step up on determinism (3 -- `fp-contract` is explicit
  and auditable rather than implicit). Toolchain maturity moved 3 -> 4
  after the literature search below found real, shipped precedent
  (RISC Zero's zkVM) for Rust producing freestanding, no-OS,
  deterministic-execution RISC-V guest binaries -- not proof that
  *this* godot-sandbox/libriscv ABI integration works, but real
  evidence the general pattern does. It still has *no* existing
  footprint in this org's tooling (1), and rewriting the whole C++ API
  surface's bindings is real, nontrivial work (2).
- **Zig** (added after the literature search, see below): a genuine,
  independently-corroborated freestanding/no_std RISC-V32 bare-metal
  code path exists (3), and its C-interop story (`@cImport`) plausibly
  lowers translation friction against the C++ reference API surface
  more than a full Rust rewrite would (3). But neither its memory/type
  safety story against a crafted-input attacker nor its float-
  determinism behavior on a freestanding RISC-V target were found
  anywhere in the search -- scored conservatively low (2, 2) rather
  than assumed, and it has zero footprint in this org's tooling (1).
- **Lean4** scores highest on safety (5 -- RFD66606-0040 called a formally
  verified guest program "the strongest answer... in principle") and
  highest on org-tooling fit (5 -- it directly extends
  `taskweft/godotweft`, `plausible-witness-dag`, and RFD66606-0026's own
  precedent). But its two weakest scores are exactly the ones that
  matter for actually shipping anything: toolchain maturity (1 --
  "never been tried by any resource this RFD references") and
  translation friction (1 -- would mean re-specifying the API surface's
  semantics from scratch, not adapting existing C++).
- **Ada/SPARK** (added after a second research pass -- see "A fifth
  candidate" below) is the highest-scoring row in this table. SPARK
  proves absence of runtime errors (buffer overflows, out-of-bounds
  access, division by zero) *at compile time, directly on the code that
  executes* -- scored a full 5 on safety, arguably the cleanest safety
  story of any candidate since it needs no separate proof-transformation
  step the way Lean4-as-verifier does. Determinism (4) is solid: SPARK's
  language subsets can constrain or ban floating-point outright via
  pragmas. Toolchain maturity (4) is backed by AdaCore's own officially
  maintained `bb-runtimes` repository, which ships a dedicated `riscv/`
  bare-metal runtime directory including a generic `spike` (the RISC-V
  reference ISA simulator, not a specific vendor board) target with real
  linker scripts and startup code -- confirmed by reading the actual
  repository contents, not assumed. It loses points on org-tooling fit
  (1 -- zero existing Ada/SPARK investment anywhere in this org) and
  translation friction (3 -- binding to the C++ API surface needs manual
  `extern "C"`-style interop, mechanical but real work).

## Runoff

Top two by total score: **C/C++ (15)** and **Lean4 (15)** tie for
first; **Rust (13)** is eliminated.

Pairwise preference across the five judges:

| Judge | Preference |
|---|---|
| 1. Safety vs. active attack | Lean4 (5 > 1) |
| 2. Determinism | tie (3 = 3), no preference |
| 3. Toolchain maturity | C/C++ (5 > 1) |
| 4. Org-tooling fit | Lean4 (5 > 2) |
| 5. Translation friction | C/C++ (5 > 1) |

**Result: 2-2, one tie.** The runoff does not resolve either, and
falling back to total score (STAR's usual tie-break) doesn't help --
both are tied there too, at 15. **This tie turns out to be an artifact
of a category error, not a genuine draw -- see the next section.**

## Category correction: the tie was a category error, not a genuine draw

The runoff above scored Lean4 as if it were an alternative *execution*
language competing directly against C/C++ -- something that itself
compiles to the freestanding RISC-V guest ELF libriscv runs. That framing
is wrong. **Lean4's real role here is as a proof verifier, not an
execution language**: it's the tool you use to state and check a
property about a specification or an implementation, not a way to
produce the thing that actually runs in the sandbox. Its low scores on
toolchain maturity (1) and translation friction (1) were already
gesturing at this -- "never been tried" and "would mean re-specifying
the API surface from scratch" aren't really "unproven but maybe
feasible," they're symptoms of asking Lean4 to do a job that isn't its
job. Once that's named plainly, the tie dissolves rather than needing a
spike to break it:

- **The execution language is C/C++** -- the only candidate left once
  Rust and Zig are blocklisted (see below) and Lean4 is correctly moved
  out of the execution-language category entirely. This is now a
  decision, not a default-by-elimination: C/C++ was never actually
  competing against a viable alternative in its own category.
- **Lean4 is the verification layer on top of that C/C++ implementation**
  -- exactly RFD66606-0040's own "formal methods on top of any of the above"
  option, now concretely resolved to "on top of C/C++" specifically,
  not left as an abstract fourth option.
- **The real open question this reframing creates**: a Lean4 proof or
  specification doesn't automatically constrain what the compiled C/C++
  binary actually does -- **the proof has to be transformed, or the
  implementation has to be checked against it, by some concrete
  mechanism.** Candidates, roughly cheapest to most rigorous:
  1. **Differential/golden-vector testing against a Lean4-extracted
     oracle** -- Lean4 can compile/extract its own specification to
     executable code that runs host-side (not in the freestanding
     guest) as a reference; the C/C++ guest implementation is tested
     against its outputs. This is exactly the pattern RFD66606-0026 already
     used ("Lean-verified reducers hand-ported line-for-line" from Lean
     sources, checked against golden vectors) -- real, working
     precedent already in this org, not a new technique to invent.
  2. **`plausible-witness-dag`-style certification** (RFD66606-0040): search
     for a counterexample where the C/C++ implementation's output
     diverges from the Lean4 spec's, across `Fin`-bounded input spaces.
     Evidence, not proof, same honest caveat as any property-based
     testing -- but cheap and already available in this org's tooling.
  3. **Frama-C/ACSL contracts + WP** (see "Hardening the toolchain"
     below): re-express the properties the Lean4 spec establishes as
     ACSL function contracts directly on the C/C++ implementation, and
     prove them with Frama-C's WP plugin. A real proof, not a test --
     stronger than options 1-2 -- but the translation from "Lean4
     theorem" to "ACSL contract" is manual and per-primitive, real
     ongoing work, not a one-time setup cost like option 1.
  4. **Full proof-carrying-code / translation validation** -- prove the
     *compiled* C/C++ binary (not just its source) actually refines the
     Lean4 spec (CompCert/seL4-style rigor). The strongest guarantee,
     and the most expensive by a wide margin; nothing found in
     RFD66606-0040's literature search suggests this org has existing tooling for
     this specific kind of proof, so it would be new, substantial
     investment rather than an extension of anything already owned.

  Option 1 is the obvious starting point precisely because it's not
  new work -- it's applying an already-proven pattern to a new domain.
  Option 3 is the natural escalation for whichever primitives turn out
  to be the most safety-critical, once Frama-C is already in the
  toolchain for the reasons named below.

Rust's and Zig's exclusion is worth stating plainly rather than
treating as a scoring-round loss: both are blocklisted on maturity
grounds as org policy, independent of their scores here. Rust in
particular scored competitively on pure merits (14, one point behind
the leaders, closer after the literature search below) -- it isn't
excluded for being unsafe or a poor technical fit, it's excluded because
this org has decided it isn't mature enough for this use case yet. That
distinction matters if this policy is ever revisited: the scoring work
already done here would still apply directly.

## A fifth candidate: Ada/SPARK (and why Nim/D didn't make the table)

A follow-up investigation, prompted directly by a request to check
whether specialized languages bypass pure C/C++'s weaknesses while
keeping toolchain compatibility, verified three more candidates. Only
one had enough concrete, checkable evidence to score:

- **Ada/SPARK**: verified directly against AdaCore's own
  `AdaCore/bb-runtimes` repository (license: GPLv3 + the GCC Runtime
  Library Exception -- the same FOSS licensing GCC itself uses, not a
  commercial-only tool like CompCert). It contains a top-level `riscv/`
  directory alongside `arm/`, `aarch64/`, `powerpc/`, `sparc/`, with a
  `spike` target specifically (the generic RISC-V reference ISA
  simulator, not a single vendor's board) shipping real linker scripts
  and startup assembly -- genuine, officially maintained bare-metal
  RISC-V support, not a community demo. Scored on the table above; see
  its rationale bullet.
- **Nim** was investigated and its central claim didn't hold up as
  strongly as described: Nim's *official* compiler user guide documents
  no true freestanding/no-OS mode at all -- its closest documented
  option, `--os:any`, explicitly still "should support only some basic
  ANSI C library stdlib and stdio functions," not zero-libc bare metal.
  A real `--os:standalone` flag does exist (found directly in Nim's own
  `lib/system.nim` source, and used in several real community
  projects -- AVR, ARM Cortex-M "narm," a Game Boy homebrew "gbnim,"
  a 4K-intro demo), so freestanding Nim is real, just undocumented in
  the official guide -- and **no RISC-V-specific precedent for
  `--os:standalone` was found anywhere**, unlike Ada/SPARK's or Zig's
  confirmed RISC-V evidence. Not scored on the main table: the
  freestanding-on-RISC-V claim specifically is unverified, not merely
  "less mature."
- **D (`-betterC` + LDC)**: a real, working example exists
  (`kubo39/ldc-riscv-baremetal`, confirmed via its own README: compiles
  with `ldc2 -mtriple=riscv32-unknown-none-elf -betterC`, links with
  `-nostdlib`, runs under `qemu-system-riscv32`) -- genuine proof the
  path works. But it is a single, zero-star, unmaintained demo
  repository last touched in 2020, with no successor or broader
  community adoption found. Not scored on the main table: real evidence
  of feasibility, but not of the toolchain maturity the scoring rubric
  is actually trying to capture.

### Runoff: Ada/SPARK vs. C/C++

Ada/SPARK's total (17) is the highest in this RFD, ahead of C/C++ and
Lean4 (15 each). Per this RFD's own STAR method, the score round only
selects finalists -- the runoff decides the winner. Since Lean4 is
correctly excluded as a non-competing verifier (see above) and Rust/Zig
are blocklisted, the real runoff is **Ada/SPARK vs. C/C++**, the two
highest-scoring *eligible execution-language* candidates:

| Judge | Preference |
|---|---|
| 1. Safety vs. active attack | Ada/SPARK (5 > 1) |
| 2. Determinism | Ada/SPARK (4 > 2) |
| 3. Toolchain maturity | C/C++ (5 > 4) |
| 4. Org-tooling fit | C/C++ (2 > 1) |
| 5. Translation friction | C/C++ (5 > 3) |

**C/C++ wins the runoff 3-2** -- it's preferred by more judges, even
though Ada/SPARK's total score is higher and its two wins (safety,
determinism) are by a much wider margin than C/C++'s three. This is a
known, honest tension in STAR voting: counting *how many* judges prefer
a candidate can disagree with *by how much*. Applying this RFD's own
stated method mechanically, C/C++ remains the decision. But given how
lopsided Ada/SPARK's wins are on the two judges that matter most for
this specific use case (an active-attacker threat model and bit-exact
lockstep determinism -- literally RFD66606-0040's stated primary criteria),
**this is flagged as a genuine judgment call for the team, not settled
by the mechanical rule alone**: a magnitude-weighted view of this same
data would plausibly favor Ada/SPARK instead.

## Literature search

A follow-on exhaustive literature search (multi-angle web search, 15
sources fetched, 53 candidate claims extracted, 25 adversarially
verified 3-way -- 17 confirmed, 8 refuted) looked specifically for any
serious candidate beyond C/C++/Rust/Lean4, and for prior art on
deterministic RISC-V guest execution generally. Casting a wide net
(Ada/SPARK, MicroPython, Nim, Swift Embedded, TinyGo, Idris 2, F*,
Dafny, Coq/Rocq, ATS, Frama-C-verified C were all explicitly searched
for) found **no evidence at all** for any of those having a freestanding
RISC-V64 + determinism story -- a genuine negative result worth
recording as searched-and-excluded rather than silently omitted, not a
gap in this RFD's diligence.

What the search *did* confirm, at high confidence from primary sources:

- **RISC Zero's zkVM is the strongest real-world precedent found for
  this entire problem shape.** It emulates a small RV32IM computer,
  and Rust ships an official (Tier 3) `riscv32im-risc0-zkvm-elf`
  target whose own docs describe the execution environment as
  "single threaded, non-preemptive, and does not support any
  privileged instructions, nor unaligned accesses" and expecting "no
  operating system... running on bare-metal." zkVM proof validity
  *requires* bit-exact deterministic replay -- the same property
  RFD66606-0040's lockstep use case needs -- and the guest memory layout is a
  fixed, embedded-style ~192MB region built with `no_std`, genuinely
  embeddable rather than a full OS process. This is real, shipped,
  production software solving a closely analogous problem, not a paper
  design.
- **RISC-V is repeatedly *proposed* in blockchain-determinism papers
  (DTVM, eBIM) as a target architecture, but in every verified case
  this is explicitly aspirational or custom-hardware co-design, not an
  implemented freestanding software guest toolchain.** RISC Zero remains
  the only verified case of an actually-shipped freestanding
  deterministic RISC-V guest environment -- worth knowing so neither
  paper is mistaken for existing tooling this RFD could adopt today.
- **Float-determinism has a real, converged-upon engineering menu from
  blockchain VM practice**, independent of language choice: ban floats
  entirely (CosmWasm's stated policy: "you cannot use floating-point
  types in smart contracts. Never."), emulate via constrained software
  softfloat (EOS-VM), or restrict to integer-only computation (DTVM's
  `dWasm` spec). Whichever language RFD66606-0040/0041 eventually settles
  on, one of these three concrete strategies -- not "just be careful
  with the compiler flags" -- is what an actual determinism-enforcement
  mechanism should look like.
- **A concrete, load-bearing caution for whichever language is chosen**:
  floating-point instructions can enter a nominally float-free guest
  binary through macro-expanded dependency code the guest author never
  wrote -- confirmed via a traced, reproduced case where Rust's `serde`
  crate's `#[serde(untagged)]` enum deserialization generates an
  internal `Content::unexpected()` conversion handling *every* possible
  JSON value variant (including `f32`/`f64`) regardless of the actual
  enum's declared variants, producing real `F64Load` instructions in
  compiled Wasm binaries that had zero float types anywhere in the
  guest author's own source. **This means "no float instructions in the
  guest" must be enforced by disassembling the actual compiled ELF and
  scanning for F-extension opcodes, not by source-level review** --
  true for any language with a package ecosystem, not specific to Rust.
- **Host-VM-level guard-page/SIGSEGV sandboxing** (DTVM reserves an 8GB
  address space, marks inactive regions `PROT_NONE`, traps out-of-
  bounds access via `SIGSEGV` rather than software bounds checks) is
  validated prior art for the *host* side of this problem -- relevant
  to libriscv's own sandboxing design, but a host-level backstop
  complementary to (not a substitute for) whichever guest-language
  safety property gets chosen; a malicious guest binary in an unsafe
  language still needs this even with a "safe" language selected.

None of this resolves the C/C++-vs-Lean4 tie directly (see revised
scoring table above), and neither Rust nor Zig changes that tie's
outcome even before the blocklist -- both remain documented as
rigorously-scored-but-currently-ineligible candidates, Rust's improved
score notwithstanding. What this search does provide, regardless of
which of the two eligible candidates eventually wins: a concrete menu
of float-determinism enforcement mechanisms to actually implement,
rather than a vague "be careful" instruction.

## Reframing the actual target: divergence, not just crashes

Everything above treated "safety" as roughly "memory-safety/UB-freedom
against a crafted-input attacker." For a lockstep distributed state
machine specifically, that's necessary but not the actual target
property. **The failure mode that matters most is silent state
divergence** -- a fork, where one node's state transition function
produces a different result than another's on the same input, with no
crash and no error to signal it happened. A memory-safety proof (IKOS,
Frama-C's Eva, CBMC's bug-hunting mode) rules out *one* source of
divergence (UB reading garbage and behaving unpredictably) but doesn't
by itself prove two implementations -- or two runs of the same
implementation -- produce bit-identical output. That's a distinct
property, and three more tools verified here target it directly:

- **Veil** (`verse-lab/veil`, confirmed Apache-2.0, 268 stars, embedded
  in Lean 4): a framework specifically for specifying, implementing,
  testing, and proving safety properties of **transition systems, with
  a stated focus on distributed protocols** -- read directly from its
  own README, not assumed. Real usage examples exist for actual
  consensus/BFT protocols (HotStuff, a DAG-based BFT protocol formalized
  in `Erchiusx/veil-dag-rider`), not just toy examples. This is a
  materially better fit for RFD66606-0040's lockstep use case than generic
  Lean4 alone: it's purpose-built to prove a transition system can't
  diverge across an unbounded number of nodes, which is exactly the
  property this RFD's guest program needs. One claim not independently
  confirmed here: whether Veil extracts proved transition-system logic
  directly to standalone C the way the framing above assumes --
  its README describes "implementing" as one of its four pillars
  alongside specify/test/prove, but the extraction mechanism itself
  wasn't verified beyond that.
- **CBMC, in equivalence-checking mode**: beyond the bug-hunting use
  already covered above, CBMC (and its hardware-focused sibling,
  `hw-cbmc`) can prove two implementations of the same function always
  produce identical output for all inputs -- a real, established
  technique (corroborated by 2026 RTL-synthesis-verification literature
  using `hw-cbmc` equivalence checking between a C reference model and
  synthesized hardware, a structurally identical problem to "prove the
  optimized C++ guest matches a simplified reference/Lean4-extracted
  oracle"). This is a stronger check than differential testing (option
  1 above): a proof that they *never* diverge across all inputs, not
  just that they agreed on the test cases actually run.
- **TLA+** (Leslie Lamport's specification language -- extremely well
  established, not independently re-verified here beyond what's already
  common knowledge): verifies the *protocol design* itself is free of
  deadlocks/race conditions/split-brain scenarios, a level above what
  any of the C-code-level tools in this RFD check. Relevant context, not
  a tool this RFD's guest-language decision needs to adopt directly --
  useful if the lockstep protocol surrounding the guest program (not the
  guest program's own arithmetic) is ever formally specified.

This reframing doesn't change the Decision below, but it does sharpen
what "verification layer" should actually mean in practice: the
differential-testing starting point (option 1) and Frama-C/IKOS-style
UB-freedom proofs both remain valuable, but **CBMC-style equivalence
checking between the C/C++ (or Ada/SPARK) implementation and a Lean4-
extracted reference is the more directly relevant proof for the
lockstep property specifically**, and Veil is worth a closer look
specifically because it targets multi-node transition-system divergence
as a first-class concern, not just single-node correctness.

### The Byzantine fault model: three more layers, if this goes that far

The reframing above (divergence, not crashes) generalizes further: under
a **Byzantine fault model**, a stochastic failure (a bit flip from
radiation) and an adversarial one (a crafted malicious input) are
mathematically indistinguishable -- both are just "a node's local state
became something the protocol didn't expect." This RFD's core scope
(the guest-program language) doesn't require going this far, but three
more tool layers verified here are worth recording since they address
this model directly, at three different levels:

1. **Design level -- adversarial fault injection**: **TLA+** (Lamport's
   specification language) and **Maude** (a rewriting-logic-based
   specification/verification system, well-established academic tooling
   not independently re-verified here beyond common knowledge) both
   support modeling an explicit adversary actor that delays, duplicates,
   or forges messages and crashes nodes, then exhaustively model-checking
   that the protocol design never reaches a split-brain state under any
   such sequence. This verifies the *protocol*, before any code exists.
2. **Protocol level -- Byzantine Fault Tolerance proofs**: **Bythos**
   (`verse-lab/bythos`, confirmed Coq, BSD-2-Clause -- genuinely FOSS,
   from the same research group as Veil above): "Compositional
   Verification of Composite Byzantine Protocols," used to prove the
   classical BFT quorum bound (`n >= 3f + 1`: safety holds as long as
   fewer than one-third of nodes are compromised at any instant). This
   is a step beyond Veil's general transition-system focus -- purpose-
   built for the specific mathematical structure of BFT quorum
   protocols.
3. **Code level -- demon-driven equivalence checking**: CBMC's
   `__CPROVER_nondet()` family (confirmed real and actively used,
   via CBMC's own regression test suite) generates a value the SMT
   solver treats as adversarially arbitrary -- "at this point, assume
   this variable/pointer/branch could be anything." Combined with
   CBMC's equivalence-checking mode (above), this can prove that even
   under worst-case local corruption, a redundancy/checksum mechanism
   (e.g. software TMR) always detects the corruption before it's
   written to committed state, rather than merely testing that it does
   on the cases actually run.

None of this changes the C/C++-vs-Ada/SPARK decision below -- it's
recorded as the natural escalation path *if* the lockstep guest program
ends up needing BFT-grade guarantees (multiple independently-operated
nodes, not just one authoritative server re-executing one client), which
RFD66606-0040's stated use case (server re-executes what the client computed)
doesn't currently require. Worth having on record before that question
comes up rather than researching it cold at that point.

## Decision

**Execution language: C/C++, per this RFD's own STAR method -- with an
explicitly flagged open dissent in favor of Ada/SPARK.** Once Lean4 is
correctly categorized as a verification tool rather than an execution-
language competitor, and Rust/Zig are excluded by standing org policy,
the eligible execution-language field is C/C++ and Ada/SPARK. C/C++
wins the mechanical runoff 3-2 (see "A fifth candidate" above) and
matches RFD66606-0040's reference API surface directly with zero translation
friction. But Ada/SPARK's two wins -- safety against active attack and
determinism, literally RFD66606-0040's stated primary criteria -- are by a
much wider margin than C/C++'s three, which this RFD does not consider
mechanically settled; it's recorded here as the team's call to make
with that tension stated plainly, not resolved by vote-counting alone.

### Hardening the toolchain: what's FOSS and what isn't

C/C++ scored lowest on safety (1) and weak on determinism (2) in the
original vote specifically because of tooling, not the language spec in
the abstract -- and the tooling choice is a separate, checkable question.
Checked directly, since a FOSS constraint applies here:

- **CompCert** (formally verified C compiler -- machine-checked proof
  that "the generated executable code behaves exactly as prescribed by
  the semantics of the source program," ruling out compiler-introduced
  bugs, plus "a full formalization and proof of floating-point
  arithmetic," with a RISC-V 32/64-bit backend since 2017) is the
  strongest available guarantee for exactly the two axes C/C++ scored
  worst on. **It is not FOSS for this use**: confirmed directly from
  CompCert's own licensing page -- free only for "evaluation, research
  and educational purposes"; "commercial uses require purchasing a
  license from AbsInt." Disqualified under the stated FOSS constraint
  unless the org later decides a paid AbsInt license is worth it as a
  deliberate exception, not a default.
- **Frama-C + ACSL** (CEA/INRIA, LGPL -- genuinely FOSS) is the
  realistic alternative for the safety axis, and comes in two
  complementary modes:
  - Its **Eva plugin** proves *absence* of exactly the bug classes an
    active attacker would target -- "invalid memory accesses, reads of
    uninitialized memory, integer overflows, divisions by zero, dangling
    pointers" -- via whole-program abstract interpretation, with no
    annotation burden on the guest author.
  - Its **WP plugin** proves the guest code satisfies specifications
    written directly in the source as **ACSL** (ANSI/ISO C Specification
    Language) function contracts -- preconditions, postconditions,
    invariants -- checked by weakest-precondition calculus. This is the
    concrete mechanism that makes "formal methods on top of C/C++" (
    RFD66606-0040's own phrase) actually executable: the specific properties the
    Lean4 spec establishes about a godot-sandbox math primitive can be
    re-expressed as ACSL contracts on the C implementation and proved
    directly, rather than only checked indirectly via differential
    testing -- a real middle ground between "test against an oracle"
    (cheap, RFD66606-0026's proven pattern) and "full translation-validation
    proof that the compiled binary refines the spec" (CompCert-grade
    rigor, real new investment). Both plugins verify properties of the
    *source*, not a proof that the compiler preserves them the way
    CompCert does; Frama-C pairs with an ordinary FOSS compiler
    (GCC/Clang) rather than replacing one.
- **Six FOSS alternatives/complements to Frama-C**, each verified by
  fetching its actual license file (not assumed from reputation) --
  worth naming because Astrée and Polyspace, the commercial tools in
  this same space, are notoriously expensive:
  - **IKOS** (NASA Ames, NASA Open Source Agreement v1.3, confirmed by
    fetching its `LICENSE.txt` directly): abstract interpretation over
    unannotated C/C++ via LLVM, purpose-built to evaluate flight-control
    systems for DO-333 (DO-178C's formal-methods supplement) certification
    credit.
  - **SeaHorn** (Modified BSD, confirmed by fetching its `license.txt`
    directly): C/C++ to LLVM IR to Constrained Horn Clauses checked by
    an SMT solver (Z3) -- push-button, no manual annotation.
  - **CPAchecker** (Apache-2.0, confirmed via GitHub's own license
    field): a configurable platform (bounded model checking,
    k-induction, predicate abstraction) that consistently places at the
    top of SV-COMP, the international software verification competition.
  - **CBMC** (BSD 4-Clause, confirmed by fetching its `LICENSE` directly):
    unrolls loops to a bound and translates execution paths into a
    SAT/SMT formula, push-button, no annotation. **Confirmed real,
    current industrial use**: `aws/s2n-tls`'s own repository has a
    `tests/cbmc` directory today -- AWS actively uses CBMC to verify its
    TLS implementation, not a claim taken on reputation alone. AWS's
    `model-checking` GitHub org (also home to Kani, AWS's Rust verifier,
    itself built on CBMC) corroborates sustained institutional
    investment beyond one project.
  - **ESBMC** (mixed licensing, confirmed by fetching its `COPYING`
    file directly -- Apache-2.0 for ESBMC's own code, BSD-4-Clause for
    its CBMC-derived base, but **some bundled SMT solvers carry
    non-commercial restrictions**, per ESBMC's own licensing document:
    "many SMT solvers linked with ESBMC contain non-commercial usage
    restrictions, making commercial distribution potentially
    problematic without careful review." The one tool in this list
    where the FOSS claim needs a caveat -- verify which solver backend
    is actually linked before relying on it commercially. Its
    distinguishing strength is native multi-threaded/concurrent C/C++
    verification (POSIX threads, atomics), which abstract interpreters
    like IKOS handle less naturally.
  - **VeriFast** (MIT, confirmed by fetching its `LICENSE.md` directly):
    uses separation logic rather than ACSL-style contracts, better
    suited to code with complex pointer/heap ownership patterns than
    Frama-C's WP -- but requires the same kind of manual annotation
    burden, and is the least industrially adopted of this group (mainly
    academic use).

  These sit alongside Frama-C's Eva/WP plugins as options for the same
  general job (proving absence of memory-safety violations); which one
  fits best is a tooling-evaluation question for whoever implements
  this, not one this RFD needs to settle. Roughly: CBMC and CPAchecker
  have the deepest real-world industrial track record among the FOSS
  options here; IKOS and Frama-C have the strongest safety-certification
  pedigree (DO-333/DO-178C, and Frama-C's documented use in France's
  aerospace/nuclear sector -- Airbus, Thales, Dassault Aviation, ONERA,
  EDF -- per Frama-C's own published case studies, not independently
  re-verified here); ESBMC and VeriFast are the specialists (concurrency,
  separation logic respectively) for codebases where those specific
  properties dominate.
- **Checked C** (Microsoft Research, a Clang fork at
  `checkedc/checkedc-clang`) adds bounds-checked pointer types to C --
  narrower and more incremental than Frama-C. Confirmed FOSS: its
  `llvm/LICENSE.TXT` is Apache License v2.0 with LLVM Exceptions, the
  same license as upstream LLVM/Clang -- unambiguously usable,
  including commercially, unlike CompCert.
- **Practical, zero-new-dependency floor**: GCC/Clang are themselves
  FOSS, and ship AddressSanitizer/UndefinedBehaviorSanitizer (dev/CI-time
  detection, not a proof) plus explicit determinism-relevant flags
  (`-ffp-contract=off`, disabling fast-math/reassociation) that directly
  implement the "auditable, controllable IEEE-754 behavior" this RFD's
  determinism judge was scoring for. Weaker than either CompCert or
  Frama-C's guarantees, but free, mainstream, and immediately usable
  with zero new toolchain risk.

Recommended combination, given the FOSS constraint: **GCC/Clang (FOSS)
+ Frama-C's Eva plugin (FOSS) for memory-safety verification, Checked C
(FOSS, Apache-2.0-with-LLVM-exceptions) for bounds-checked pointer types
where incremental adoption is cheaper than a full Eva pass, plus
explicit strict-FP compiler flags for determinism** -- not CompCert,
despite it being the strongest single guarantee, specifically because
it fails the stated FOSS requirement for anything beyond research use.

**Verification layer, chosen: Lean4 spec -> CBMC (or `hw-cbmc`, its
hardware-verification cousin) equivalence checking.** Of the options
enumerated in "Category correction" and sharpened in "Reframing the
actual target" above, this RFD settles on the equivalence-checking path
specifically, not differential testing alone: Lean4 states the
specification for each godot-sandbox math primitive the lockstep guest
needs; CBMC (or `hw-cbmc` where the primitive's structure is closer to
a hardware-style datapath -- fixed-width bit manipulation, saturating
arithmetic -- than to general C control flow) proves the C/C++ (or
Ada/SPARK, pending that open dissent above) implementation produces
*provably identical* output to the Lean4-extracted reference across
*all* inputs, not just the cases a differential test suite happens to
run. This is a real proof of the property that matters most for
lockstep specifically (see "Reframing" above), while stopping short of
full translation-validation/proof-carrying-code (option 3/4) -- CBMC
proves the two implementations agree, not that the compiler preserves
that agreement down to the compiled binary, which remains real,
substantial investment this RFD doesn't attempt to justify starting
cold.

Two concrete follow-ups this RFD identifies, neither requiring a fresh
vote:

1. Build the Lean4 spec for whichever godot-sandbox math primitives the
   lockstep guest program actually needs, extract it as CBMC's
   reference side, and write the CBMC (or `hw-cbmc`) equivalence-check
   harness proving the C/C++ implementation matches it -- direct,
   scoped engineering work, not a research spike, and a stronger
   guarantee than RFD66606-0026's differential-testing pattern alone (which
   remains a reasonable interim step while the equivalence harness is
   being built, not the final target).
2. Pick one of the three float-determinism enforcement strategies
   surfaced by the literature search (ban/softfloat/integer-only) and
   verify it holds by disassembling the actual guest ELF for
   F-extension opcodes, not by source review alone -- the serde/Wasm
   precedent above shows source review alone misses macro-injected
   float instructions.

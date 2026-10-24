---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: discussion
discussion: N/A -- not yet reviewed
labels: sandbox, godot, determinism, lockstep, floating-point
---

# 0042 Float-determinism enforcement strategy: a STAR-voted choice

## Context

RFD66606-0040's literature search surfaced three float-determinism
enforcement strategies converged on by blockchain-VM engineering
practice: ban floating-point entirely (CosmWasm), emulate via
constrained software softfloat (EOS-VM), or restrict to integer-only
computation (DTVM's `dWasm`). RFD66606-0041 recorded these as "a concrete
menu... rather than a vague 'be careful' instruction" but didn't choose
between them. This RFD does, using the same STAR-voting method as
RFD66606-0041 (score round, then an automatic runoff between the top two).

**A fourth candidate is added here, found by checking canonical prior
art in game networking specifically** (the blockchain-VM literature
this menu came from solves a related but different problem -- smart
contracts, not real-time 3D simulation): Glenn Fiedler's
`gafferongames.com`, a widely cited primary source in this exact space,
recommends **disciplined native IEEE-754 floating point** (strict
compiler modes, no `-ffast-math`, controlled FPU/rounding-mode state)
over abandoning floats, for deterministic game replay/lockstep --
explicitly warning that naive cross-platform native float code is not
reproducible, but not concluding floats must be avoided. That warning's
premise -- *different* CPUs/compilers/architectures on each end -- does
not hold for this repo's specific architecture: the guest program runs
as a RISC-V ELF through the same `libriscv` software interpreter on
both the Godot client and the zone-backend server, not as natively
compiled code on two different real CPUs. This changes the calculus
enough to score as a serious fourth candidate, not dismiss as "the naive
option blockchain VMs already rejected."

## Method

Same as RFD66606-0041: **STAR** (Score Then Automatic Runoff). Five judges,
each scoring every candidate 0-5; scores sum to select the top
candidates, and an automatic runoff between them decides the winner by
pairwise judge preference.

**Judges:**

1. **Determinism guarantee strength** -- how airtight is bit-exact
   reproducibility, specifically within this repo's guest-program-in-
   libriscv architecture (not the general cross-platform case).
2. **API compatibility with the reference godot-sandbox surface** --
   `Variant`, `Vector2/3/4`, `Quaternion`, `Transform2D/3D`, `Basis`
   (RFD66606-0040's item 2) are all float-typed in the reference C++ API;
   this judge scores how much of that surface survives unchanged.
3. **Performance** -- runtime cost of the strategy inside the guest.
4. **Implementation effort** -- one-time engineering cost to adopt.
5. **Precedent for this specific use case** -- real-world track record
   for deterministic *game*/real-time-simulation replay specifically,
   not just blockchain smart contracts (a related but distinct domain
   with different performance and API-surface constraints).

## Scoring round

| Judge | Ban floats | Softfloat | Fixed-point/integer-only | Strict native float |
|---|---|---|---|---|
| 1. Determinism (in this architecture) | 5 | 5 | 5 | 4 |
| 2. API compatibility | 1 | 5 | 2 | 5 |
| 3. Performance | 3 | 1 | 5 | 5 |
| 4. Implementation effort | 2 | 3 | 2 | 5 |
| 5. Precedent for game/real-time use | 3 | 4 | 4 | 4 |
| **Total** | **14** | **18** | **18** | **23** |

Rationale per cell:

- **Ban floats entirely** is trivially deterministic (5) since there's
  nothing float-shaped left to diverge, but scores worst on API
  compatibility (1): the entire reference godot-sandbox math surface is
  float-typed, so this strategy means not using that API as designed at
  all, not adapting it. Its precedent (3) is real but comes entirely
  from blockchain VMs (CosmWasm) verifying token-transfer logic, a
  domain with no inherent need for continuous math -- no equivalent
  precedent was found for a 3D/graphics-math use case specifically.
- **Softfloat emulation** keeps the reference API surface unchanged (5
  -- swap the underlying op implementation, not the interface) and is
  deterministic by construction (5), but pays a real, serious
  performance cost (1) -- software floating-point is well known to run
  one to two orders of magnitude slower than hardware FPU, a cost that
  compounds every tick in a real-time simulation the way it wouldn't in
  an infrequently-called smart contract. Precedent (4) is real and
  confirmed (EOS-VM, RFD66606-0040's literature search).
- **Fixed-point/integer-only** is bit-exact by construction (5) and
  typically fast (5 -- often faster than even native hardware float),
  but requires rebuilding the reference API's math surface around a
  fixed-point representation rather than the float types it actually
  uses (2), and that rebuild is a real, nontrivial one-time cost (2).
  Precedent (4) for deterministic real-time simulation generally is
  well known in the games industry (RTS and fighting games have used
  fixed-point specifically to sidestep cross-platform float
  non-determinism for decades) -- flagged here as widely-known industry
  practice, not backed by one specific verified citation the way the
  blockchain-VM precedents above were.
- **Strict native float** wins on every judge except determinism, where
  it's a close second (4, not 5): unlike softfloat/fixed-point/ban,
  which are deterministic *unconditionally*, this strategy's guarantee
  depends on getting compiler-flag discipline right (no FMA contraction
  drift between builds, pinned rounding mode) -- real but a smaller,
  well-understood risk given the RISC-V compiler backend used to
  produce the guest ELF is fixed and known, not "whatever compiler each
  player's client happened to use" the way Fiedler's article is
  actually warning about. It needs zero changes to the reference API
  surface (5), runs at native hardware-float speed inside the guest
  (5), and requires the least new engineering (5 -- compiler flags, not
  a new math library). Its precedent (4) is a well-respected primary
  source (`gafferongames.com`) for the *general* problem this strategy
  addresses, applied here to a specifically *easier* version of that
  problem (one interpreter, not N divergent native platforms).

## Runoff

Top score: **strict native float (23)**, a clear lead over the tied
runners-up **softfloat (18)** and **fixed-point (18)** (ban floats, 14,
eliminated). Checking the pairwise runoff against each tied candidate,
since STAR's own method only guarantees a top-two runoff and this is a
three-way tie for the remaining slot:

**Strict native float vs. softfloat:**

| Judge | Preference |
|---|---|
| 1. Determinism | Softfloat (5 > 4) |
| 2. API compatibility | tie (5 = 5) |
| 3. Performance | Native (5 > 1) |
| 4. Implementation effort | Native (5 > 3) |
| 5. Precedent | tie (4 = 4) |

Native wins 2-1 (two ties).

**Strict native float vs. fixed-point:**

| Judge | Preference |
|---|---|
| 1. Determinism | tie (5 = 5) |
| 2. API compatibility | Native (5 > 2) |
| 3. Performance | tie (5 = 5) |
| 4. Implementation effort | Native (5 > 2) |
| 5. Precedent | tie (4 = 4) |

Native wins 2-0 (three ties).

**Strict native float wins both possible runoffs.** Unlike RFD66606-0041's
C/C++-vs-Ada/SPARK result, this one isn't close: native float doesn't
just win on judge count, it never loses a single judge outright against
either alternative.

## Decision

**Float-determinism strategy: strict native IEEE-754 floating point**,
disciplined by compiler flags (`-ffp-contract=off`, no fast-math/
reassociation, pinned rounding mode) rather than banned, software-
emulated, or replaced with fixed-point. This works specifically because
of this repo's architecture: the guest ELF runs through the same
`libriscv` interpreter on both the Godot client and the zone-backend
server, so the cross-platform-native-float non-determinism
`gafferongames.com` warns about doesn't apply the way it would to
natively-compiled code running on players' actual, differing CPUs.

This is not a claim that the risk is zero -- RFD66606-0040's own
float-instrumentation caution still applies (float instructions can
enter a guest via macro-expanded dependency code the author never
wrote; verify by disassembling the actual guest ELF for F-extension
opcodes and their exact form, not by source review alone) -- and it
should be verified, not assumed, once real godot-sandbox math
primitives are implemented: build a small guest program exercising the
`Vector`/`Quaternion`/`Transform` operations the lockstep use case
actually needs, run it through `libriscv` on two different host
machines/OSes, and confirm bit-identical output. That confirmation is
cheap (no new tooling, no new math library) precisely because this
strategy requires neither.

## Non-decision

Softfloat and fixed-point remain documented, scored fallbacks if the
verification step above ever fails to hold in practice -- not
discarded, just not the starting point. Ban-floats-entirely is excluded
outright: its only advantage (unconditional determinism) is matched by
both fallbacks without its API-incompatibility cost.

---
authors: K. S. Ernest (iFire) Lee <ernest.lee@chibifire.com>
state: published
discussion: N/A -- committed directly, no PR review
labels: gyre, scope, tombstones, foundationdb, cockroachdb, planner
---

# 0044 The Gyre ships web-first on zone-backend; zone-server-h2o archived, FDB tombstoned for player state

## Context

A single working session took The Gyre (RFD66606-0085) from a 919,261-byte
three.js client to a merged, playable web game, and collapsed the
surrounding architecture to two repos. This records what was decided and
what was killed, with dates, so none of it is relitigated.

The session churned badly before settling. Six architectures were proposed
and dropped in sequence. That churn is itself the reason for the tombstone
table below.

## Tombstones

Every entry was proposed, examined, and closed on 2026-08-07.

| Factor | Why it died | Record |
| --- | --- | --- |
| CockroachDB for *zone* state | Raft loses to log-structured MVCC at 88% writes | RFD66606-0075 |
| FDB Record Layer | It is Java. RFD66606-0075 chose raw `libfdb_c` to avoid the JVM | RFD66606-0075 |
| Postgres fork inside libriscv | Needs `fork()`, shm, signals, a filesystem | RFD66606-0095 |
| SQLite over `ZONE_KV_*` | A SQL parser over a KV store, to reach state the guest addresses directly | -- |
| A TUI | "no tui. webfirst." | -- |
| ttyd | A binary, not a C ABI library. WebSocket, not H3/WT | -- |
| A second standalone C host | Rebuilds `zone-server-h2o`'s event loop, transport and FDB wiring | -- |
| A hand-rolled ranking heuristic | The planner already exists in this repo | -- |
| `taskweft_nif` (native) | Retired; sandbox adapters are the only path | ADR 0038 |
| `multiplayer-fabric-uro.fly.dev` | No DNS record | -- |
| `hub.chibifire.com` | Dead | -- |
| `zone-server-h2o` | **Archived.** No budget to split it out | -- |
| The Gyre C guest | No host once the above was archived | -- |
| libriscv guests, picoquic H3/WT, raw `libfdb_c` | All lived in `zone-server-h2o` | -- |
| **FDB for player state** | Parity at 0.8% load -- see below | RFD66606-0075 |

Live after all of that: **zone-backend and zone-client only.**
Elixir/Phoenix, `Uro.Planner`, CockroachDB, web first.

## FDB for player state: tombstoned on parity

RFD66606-0075 chose FDB over CockroachDB on five points. Four are void now that
`zone-server-h2o` is archived, and the fifth inverts.

| RFD66606-0075 said | Now |
| --- | --- |
| "TPC-C is 88% writes... the database is the bottleneck" | Player state is not that workload |
| "Active Apple development" | True, and irrelevant if unused |
| "Pure C client... integrating naturally with h2o's event loop" | h2o is archived |
| "Native ACID... no `BEGIN`/`COMMIT` SQL parsing" | zone-backend *is* SQL, via Ecto |
| "No SQL layer overhead" | **Inverts.** FDB would *add* a KV mapping layer to an Ecto app |

Measured against the workload we actually have:

| | Capacity | The Gyre at 5,000 CCU |
| --- | --- | --- |
| FoundationDB 7.3, one core | 35,000 writes/sec | 1.43% |
| CockroachDB 20.2, 140K warehouses | 1.7M tpmC, about 62,963 tx/sec | 0.79% |

At one action per player per 10 seconds, 5,000 CCU (RFD66606-0082's own target)
is 500 tx/sec. Both are over-provisioned by two orders of magnitude, so
throughput does not discriminate between them here.

The deciding factor is the adapter. `ecto_foundationdb` has no joins and no
aggregates, and only gained `IN` during this session. CockroachDB is
already wired, already migrated, already running all 12 schemas.

**Revisit if** player state becomes write-bound at 64Hz. That is the
zone-tick shape, not this one.

## What shipped

**The web game** (PR #53). One self-contained HTML file at
`/gyre/index.html`, **16,421 bytes**, no build step and no framework
runtime. It replaces 919,261 bytes of three.js and SlugHorn WASM. The only
external dependency is `ninja-keys` for the slash palette. Narration is
written with `textContent` throughout, never `innerHTML`.

It runs standalone because the MUD server it would have called no longer
exists: `zone-server-h2o` has no `mud/` directory and no `MUD_HTTP_PORT`.

**The palette** (PR #55). Sampled from the Silent Witch OP with `yt-dlp`
and `ffmpeg palettegen`, weighted by screen time over 1,310,400 pixels.
Two hues: cool blue is the dark, warm cream is the light, and that axis
carries Frame integrity. No red or green appears in the source, so none is
invented -- health reads blue when sound.

Method note: the on-screen cut produced a `#00ff00` chroma artifact and only
one saturated hue, both artifacts of burned-in credits. **Sample creditless
sources.**

**The System** (`Uro.Gyre.Domain`). Predictive slash commands through the
real `Uro.Planner.ElixirAdapter` -- no new dependency, since the planner is
already in `lib/uro/planner/`.

It is diegetic: the thing that digitised you and holds your debt is the
same thing suggesting your next move. **It is always helpful, unfailingly,
and that is the joke.** It congratulates you on a contract costing 14% of
your Frame, and is delighted to process a payment leaving you with nothing.
The horror is never in the tone, only in what the tone is applied to.

There is deliberately no integrity guard on `work`. The System recommends
working a Frame that the action ends, quoting the 1,200 cr decant fee in the
same breath, as a courtesy.

Using the real planner paid immediately: it caught two ordering bugs on the
first run, advising a new contract where the correct calls were `repair`
and `pay`.

## Deploy, stated plainly

There is **no deployed URL**. `build-image.yml` pushes to
`ghcr.io/v-sekai-multiplayer-fabric/zone-backend` and stops there. Deploy is
manual `flyctl`, off-repo, against an app not named in this repository.

CI was also red from `ce2d3c6` (2026-08-07 10:57) until PR #54, on two
formatting lines in `config/config.exs`. PR #53 merged into that red main,
because auto-merge was enabled while checks were still pending.

## Consequences

The C guest written this session (`gyre_guest.c`: raw C, eight ecalls, 13
passing native tests) has no home and was not committed anywhere. That is a
real loss, and the correct call given the budget. Archiving is read-only
and reversible, so nothing is destroyed.

Milestone convention, agreed in the same session: **on a shipped
user-visible change**, drive the game through Playwright, assert state, then
screenshot to `~/Desktop`. Assert before shooting -- a screenshot of a
broken page is worse than none.

# AGENTS.md — multiplayer-fabric-zone-backend

Uro — Phoenix/Elixir backend for zone registration, asset management, and
authentication. Deployed on Fly.io as `multiplayer-fabric-uro`.

## Fly.io deployment

The lobby API deploys from `fly/api/` as the private app `vsekai-lobby-api`
(`fly deploy --config fly/api/fly.toml --no-public-ips`); `fly/web/` is the
public web app in front of it.

### Storage

`Uro.Repo` is SQLite with its pages in FoundationDB: datasource-store's
`weft_fdb` VFS, loaded from `URO_WEFTFDB_EXTENSION` (`lib/uro/repo/weft_fdb.ex`).
The database is `URO_DATABASE` (`file:<name>?vfs=weft_fdb`). A weft_fdb database
admits one connection, so the pool size is 1 and migrations run through
`Uro.Repo` before the endpoint starts. Dev uses a plain SQLite file
(`config/dev.exs`). CockroachDB is retired.

### Required Fly secrets

| Secret | Purpose |
|--------|---------|
| `FDB_CLUSTER_CONTENT` | FoundationDB cluster file, written by `fly/api/entry.sh` |
| `FDB_TLS_CERT_B64`, `FDB_TLS_KEY_B64`, `FDB_TLS_CA_B64` | FoundationDB client TLS |
| `PHOENIX_KEY_BASE` | 64-byte secret key base |
| `JOKEN_SIGNER` | JWT signing key |
| `SIGNUP_API_KEY` | Client signup API key |
| `LOOP_API_KEY` | Loop-server profile commit API key (`POST /api/v1/loop/commit`) |

### Startup script

`fly/api/entry.sh` writes the cluster file and TLS files, waits until
`fdbcli` reports the cluster available, runs `mix ecto.migrate`, then starts
`phx.server`.

### Known quirks

- `Helpers.get_env/2` uses `@compile_phase?` baked at build time — env vars for
  non-nil defaults must be set as Fly secrets, not inferred from the example values.
- `socket_options: [:inet6]` is required — Fly `.internal` DNS returns IPv6 only.

---

Guidance for AI coding agents working in this submodule.

## Commit message style

Sentence case, imperative verb, no Conventional Commits prefix, under 72
characters. See the root `AGENTS.md` for examples.

## Test commands

```sh
mix test                           # unit tests
mix test --only prod               # integration tests (requires live stack)
mix credo --min-priority high      # linting
mix format --check-formatted       # formatting
```

Integration tests require a running stack (`docker compose up -d`) and
these env vars:

```sh
AWS_S3_BUCKET=uro-uploads
AWS_S3_ENDPOINT=http://localhost:7070
AWS_ACCESS_KEY_ID=minioadmin
AWS_SECRET_ACCESS_KEY=minioadmin
```

(Zone-console client env vars — `URO_BASE_URL`, `URO_EMAIL`, `ZONE_CERT_HASH_B64`,
etc. — belong in `multiplayer-fabric-zone-console/AGENTS.md`.)

## Red-green-refactor

1. **RED** — write a failing test with a specific, load-bearing error message.
   Briefly break the assertion to confirm the failure is not vacuous.
2. **GREEN** — write the minimum code to pass the test. No extra abstractions.
3. **REFACTOR** — clean up with tests still green. One commit per cycle.

The TDD arc must be legible in `git log`.

## Elixir conventions

- Use PropCheck generators rather than mocks.
- Functions return `{:ok, value}` / `{:error, reason}` at every boundary.
  `raise` is for programmer errors (wrong type, missing config at boot),
  never for runtime conditions.
- Migrations are forward-only. Once merged to main, never alter a migration.
  Every migration must include a `down/0`. Generate with:
  ```sh
  mix ecto.gen.migration <name>
  ```
  Then add the SPDX header manually (the generator does not add it and the
  pre-commit hook will reject the file without it — see SPDX requirement below).

## SPDX requirement

Every new first-party `.ex` or `.exs` file must contain both of these lines
in the first 2 KB:

```elixir
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
```

This is enforced by `scripts/check_spdx.py` via the pre-commit hook. Files
missing either line will block the commit. Generated files (`mix ecto.gen.migration`,
`mix phx.gen.*`) need the header added manually before staging.

## Asset implementation cycles

| Cycle | Feature | Status |
|-------|---------|--------|
| 1 | `UroClient.login/3` | done |
| 2 | `UroClient.upload_asset/3` — chunk → VersityGW → uro manifest | done |
| 3 | `UroClient.get_manifest/2` | done |
| 4 | `CMD_INSTANCE_ASSET` wire encoding (100-byte packet) | done |
| 5 | `instance` console command — sends packet to zone server | done |
| 6 | Asset baker — Docker `editor=yes`, casync `.caidx` output | done |
| 7 | Zone orchestrator — Docker `editor=no` zone server lifecycle, port pool UDP 7443–7542 | planned |
| 8 | Godot zone handler — authority zone runs instance pipeline | planned |
| 9 | Round-trip smoke test — upload → instance → entity list on prod | planned |
| 10 | Two-user co-presence — second client connects, observes entity from first client | planned |
| 11 | Multi-platform verification — macOS + Linux + Windows, AccessKit | planned |

## PoC runbook (cycles 9–10)

Prerequisites: stack running (`docker compose up -d`), two terminals,
`zone_console` binary built (`mix escript.build` in
`multiplayer-fabric-zone-console/`).

**Terminal 1 — User A:**

```sh
> login
Username/email: user-a@example.com
Password: ****
Logged in as user-a

> upload path/to/avatar.tscn
Uploaded avatar.tscn as <ASSET_ID>

> bake-status <ASSET_ID>
Baking... (polling every 2 s)
Baked. baked_url = http://versitygw:7070/uro-uploads/<ASSET_ID>.caidx

> join 0
Joined zone 0 at zone-700a.chibifire.com:7443

> instance <ASSET_ID> 0.0 1.0 0.0
Instance request sent

> entities
[zone 0]  id=42  pos=(0.00, 1.00, 0.00)  type=scene  asset=<ASSET_ID>
```

Entity appears → cycle 9 proved.

**Terminal 2 — User B:**

```sh
> login
Username/email: user-b@example.com
Password: ****
Logged in as user-b

> join 0
Joined zone 0 at zone-700a.chibifire.com:7443

> entities
[zone 0]  id=42  pos=(0.00, 1.00, 0.00)  type=scene  asset=<ASSET_ID>
```

Same entity visible to User B → cycle 10 proved. Minimal V-Sekai PoC complete.

**Monitoring:**

```sh
docker logs <baker-container-id>

nc -u -w2 zone-700a.chibifire.com 7443 && echo "UDP open"
```

# contract-zone-backend

Uro, the Phoenix service that registers zone servers, stores and serves uploaded assets, and signs users in.

## Use

Zone servers register themselves with Uro when they start and keep a heartbeat, so it holds no zone list of its own. The `Uro` module's documentation describes the data model, and `AGENTS.md` holds the test commands.

## Build and run

Run Uro with its development database in a local file:

```sh
mix deps.get && mix ecto.setup && mix phx.server
```

### Serve on a local SQLite file

`mix phx.server` in dev starts the app but opens no HTTP port. To serve, run in `prod` with `URO_WEFTFDB_EXTENSION` unset, so `URO_DATABASE` is a plain SQLite file (WAL, pool of `POOL_SIZE`, default 5):

```sh
export MIX_ENV=prod PORT=4010 URL=http://localhost:4010 ROOT_ORIGIN=http://localhost:4010 \
  FRONTEND_URL=http://localhost:4010 URO_DATABASE=/var/db/uro/uro.db ARIA_STORAGE_DB=/var/db/uro/aria.db \
  UPLOAD_STORAGE=local UPLOAD_DIR=/var/db/uro/uploads \
  PHOENIX_KEY_BASE=$(openssl rand -hex 48) JOKEN_SIGNER=$(openssl rand -hex 32)
mix deps.get && mix ecto.create && mix ecto.migrate && mix run --no-halt
```

`GET /health` then answers 200. With `URO_WEFTFDB_EXTENSION` set, the FoundationDB layout applies as before.

The build compiles a native sandbox library, so CMake and Ninja must be on the path. The `docker-compose.yml` stack does not match the current database and is not a supported way to run Uro.

## Licence

MIT. See `LICENSE`.

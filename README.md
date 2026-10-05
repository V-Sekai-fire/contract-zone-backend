# contract-zone-backend

Uro, the Phoenix service that registers zone servers, stores and serves uploaded assets, and signs users in.

## Use

Zone servers register themselves with Uro when they start and keep a heartbeat, so it holds no zone list of its own. The `Uro` module's documentation describes the data model, and `AGENTS.md` holds the test commands.

## Build and run

Copy `.env.example` to `.env`, fill it in, and start the stack:

```sh
docker compose up -d
```

To run Uro alone, with its development database in a local file:

```sh
mix deps.get && mix ecto.setup && mix phx.server
```

The build compiles a native sandbox library, so CMake and Ninja must be on the path.

## Licence

MIT. See `LICENSE`.

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
import Config

weftfdb = System.get_env("URO_WEFTFDB_EXTENSION")
config :uro, :weftfdb_extension, weftfdb

# With the weftfdb extension the test database is a weft_fdb one, which admits one connection.
config :uro,
       Uro.Repo,
       [
         show_sensitive_data_on_connection_error: true,
         database: System.get_env("TEST_DATABASE", Path.expand("../priv/uro_test.db", __DIR__)),
         stacktrace: true,
         migration_lock: false,
         # The migrator runs each migration in its own process, which the sandbox
         # refuses on a one-connection weft_fdb database; CI migrates with a plain pool.
         pool:
           if(System.get_env("URO_MIGRATION_POOL"),
             do: DBConnection.ConnectionPool,
             else: Ecto.Adapters.SQL.Sandbox
           )
       ] ++
         if(weftfdb,
           do: [
             pool_size: 1,
             journal_mode: :memory,
             locking_mode: :exclusive,
             # Sandboxed async tests queue on the one connection; wait rather than drop.
             queue_target: 5_000,
             queue_interval: 30_000
           ],
           else: [pool_size: 10]
         )

# Sessions and sealed second factors need a key base; the server stays off.
config :uro, Uro.Endpoint,
  server: false,
  secret_key_base: String.duplicate("uro-test-key-base-", 4)

# The tests release leases themselves; the janitor stays out of the sandbox.
config :uro, :agent_task_janitor_interval, 24 * 60 * 60 * 1000

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
         pool: Ecto.Adapters.SQL.Sandbox
       ] ++
         if(weftfdb,
           do: [pool_size: 1, journal_mode: :memory, locking_mode: :exclusive],
           else: [pool_size: 10]
         )

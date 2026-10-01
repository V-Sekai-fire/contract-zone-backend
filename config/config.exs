# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
import Config

# Everything that needs a real deploy-time secret or URL now lives in
# config/runtime.exs, evaluated once at release boot, not here. This
# file only holds config that is genuinely safe to bake in at compile
# time (mix release freezes this file's content permanently into the
# release, evaluated once, at build time -- unlike runtime.exs, which
# the release re-evaluates every time it actually starts).
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 4, cleanup_interval_ms: 60_000 * 10]}

config :uro,
  ecto_repos: [Uro.Repo]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :uro, :stale_zone_cutoff,
  amount: 3,
  calendar_type: "month"

config :uro, :stale_zone_interval, 30 * 24 * 60 * 60 * 1000

config :uro, :rebac_adapter, Uro.ReBAC.ElixirAdapter
config :uro, :planner_adapter, Uro.Planner.ElixirAdapter

config :uro, :pow,
  user: Uro.Accounts.User,
  users_context: Uro.Accounts,
  repo: Uro.Repo,
  web_module: Uro,
  extensions: [PowPersistentSession],
  controller_callbacks: Pow.Extension.Phoenix.ControllerCallbacks,
  routes_backend: Uro.Pow.Routes,
  cache_store_backend: Uro.Pow.DetsCache

config :uro, :pow_assent, user_identities_context: Uro.UserIdentities

config :uro, :registration_open, false

config :waffle,
  storage: Waffle.Storage.Local

# aria-storage uses SQLite for internal chunk metadata. Real path
# (prod) comes from config/runtime.exs; this is the dev/test default.
config :aria_storage, AriaStorage.Repo, database: "priv/aria_storage.db"

import_config "#{Mix.env()}.exs"

if Mix.env() == "dev" do
  import_config "local.exs"
end

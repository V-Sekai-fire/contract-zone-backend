# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Repo do
  use Ecto.Repo,
    otp_app: :uro,
    adapter: Ecto.Adapters.SQLite3,
    migration_lock: false

  use Scrivener, page_size: 10

  # Runs wherever the repo starts (the app, mix ecto.* tasks, releases' migrate).
  @impl true
  def init(_context, config) do
    if Uro.Repo.WeftFdb.load_configured!() == :loaded,
      do: {:ok, Keyword.put(config, :pool_size, 1)},
      else: {:ok, config}
  end
end

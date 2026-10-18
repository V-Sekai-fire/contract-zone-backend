# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule UroLoop.Ports.ProfileStore do
  @moduledoc """
  Output port for persisting loop player profiles.

  Implement this behaviour in an adapter to supply storage. The default
  adapter is `Uro.Loop.EctoProfileStore` (Ecto, SQLite on FoundationDB), which
  lives in the zone-backend app. Tests can inject an in-memory fake via
  `Application.put_env(:uro, :loop_profile_store, FakeStore)`.
  """

  @type profile :: %{String.t() => term()}

  @doc """
  Atomically replace the item set for each named player.

  Each entry must contain `"name"` (string) and `"items"` (list of integers).
  """
  @callback commit(profiles :: [profile()]) :: {:ok, any()} | {:error, any()}
end

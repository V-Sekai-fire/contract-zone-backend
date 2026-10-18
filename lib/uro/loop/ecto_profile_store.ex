# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Loop.EctoProfileStore do
  @moduledoc """
  Ecto adapter (SQLite on FoundationDB) for `UroLoop.Ports.ProfileStore`.

  This is the only module in the zone-backend that imports `Ecto.Query` or
  touches `Uro.Repo` on behalf of the loop cluster. Domain logic and port
  definitions live in the `:uro_loop` library.
  """

  @behaviour UroLoop.Ports.ProfileStore

  import Ecto.Query
  alias Uro.Repo
  alias Uro.Loop.{Item, Player}

  @impl true
  def commit(profiles) when is_list(profiles) do
    Repo.transaction(fn ->
      Enum.each(profiles, fn %{"name" => name, "items" => items} ->
        player = upsert_player(name)
        Repo.delete_all(from i in Item, where: i.loop_player_id == ^player.id)

        Enum.each(items, fn item_id ->
          Repo.insert!(%Item{loop_player_id: player.id, item: item_id})
        end)
      end)
    end)
  end

  defp upsert_player(name) do
    case Repo.get_by(Player, name: name) do
      nil -> Repo.insert!(Player.changeset(%Player{}, %{name: name}))
      existing -> existing
    end
  end
end

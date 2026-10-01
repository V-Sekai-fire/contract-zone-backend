# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.VSekai do
  @moduledoc """
  The VSekai context.
  """

  import Ecto.Query, warn: false
  alias Uro.Repo

  alias Uro.SharedContent.SharedFile
  alias Uro.VSekai.Zone

  def zone_freshness_time_in_seconds, do: 30

  def list_zones do
    Zone
    |> Repo.all()
    |> Repo.preload(user: [:user])
  end

  # Unauthenticated: public zones only.
  def list_fresh_zones do
    stale_timestamp =
      DateTime.add(DateTime.utc_now(), -zone_freshness_time_in_seconds(), :second)

    Repo.all(
      from z in Zone,
        where: z.last_put_at > ^stale_timestamp and z.public == true,
        preload: [:user]
    )
  end

  # Authenticated: public zones + zones this user owns.
  # Private zones the user was invited to are accessed via direct URL; CAN_ENTER
  # is checked at WebTransport connect time by the zone server, not here.
  def list_fresh_zones(user_id: user_id) do
    stale_timestamp =
      DateTime.add(DateTime.utc_now(), -zone_freshness_time_in_seconds(), :second)

    Repo.all(
      from z in Zone,
        where: z.last_put_at > ^stale_timestamp and (z.public == true or z.user_id == ^user_id),
        preload: [:user]
    )
  end

  @doc """
  Check whether `player_id` may enter `zone` using the ReBAC CAN_ENTER relation.
  Public zones always admit entry. Private zones require an explicit CAN_ENTER
  edge (or a chain: OWNS implies CAN_ENTER).

  Called at WebTransport connect time — not at listing time.
  """
  def can_enter_zone?(%Zone{public: true}, _player_id), do: true

  def can_enter_zone?(%Zone{} = zone, player_id) do
    graph =
      Uro.ReBAC.new_graph()
      |> Uro.ReBAC.add_edge(to_string(zone.user_id), to_string(zone.id), "OWNS")
      |> Uro.ReBAC.add_edge(to_string(zone.user_id), to_string(zone.id), "CAN_ENTER")

    Uro.ReBAC.check_rel(graph, to_string(player_id), "CAN_ENTER", to_string(zone.id))
  end

  def get_zone!(id) do
    Zone
    |> Repo.get!(id)
    |> Repo.preload(user: [:user_privilege_ruleset])
  end

  def create_zone(attrs \\ %{}) do
    zone_data = Map.get(attrs, "shard", %{})
    flattened_attrs = Map.merge(Map.drop(attrs, ["shard"]), zone_data)

    %Zone{}
    |> Zone.changeset(flattened_attrs)
    |> Ecto.Changeset.put_change(:last_put_at, DateTime.utc_now())
    |> Repo.insert()
  end

  def update_zone(%Zone{} = zone, attrs) do
    zone
    |> Zone.changeset(attrs)
    |> Ecto.Changeset.put_change(:last_put_at, DateTime.utc_now())
    |> Repo.update(force: true)
  end

  def delete_zone(%Zone{} = zone) do
    Repo.delete(zone)
  end

  def change_zone(%Zone{} = zone) do
    Zone.changeset(zone, %{})
  end

  def get_zone_by_address(address) when is_nil(address), do: nil

  def get_zone_by_address(address) do
    Repo.get_by(Zone, address: address)
  end

  # Returns the casync .caidx baked_url for the SharedFile whose name matches
  # map_name, or nil if not yet baked. Convention: SharedFile.name == zone.map.
  def get_desync_url_for_map(nil), do: nil

  def get_desync_url_for_map(map_name) do
    SharedFile
    |> where([f], f.name == ^map_name and not is_nil(f.baked_url))
    |> order_by([f], desc: f.created_at)
    |> limit(1)
    |> select([f], f.baked_url)
    |> Repo.one()
  end
end

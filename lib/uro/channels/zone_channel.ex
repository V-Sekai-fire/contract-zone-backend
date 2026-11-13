# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.ZoneChannel do
  use Uro, :channel

  alias Uro.VSekai
  alias Uro.Zones.Slots

  # Client joins "zone:{zone_id}" and receives the desync index URL immediately, with the
  # slot it was given and the zone's four slots (user ids or nil).
  # When the zone server sends a PUT /shards/:id heartbeat, zone-backend
  # broadcasts "zone_updated" to all subscribers so clients fetch fresh chunks.
  #
  # A user who may not enter the zone, or who finds all four slots taken, is refused.
  def join("zone:" <> zone_id, _params, socket) do
    zone = VSekai.get_zone!(zone_id)
    user_id = socket.assigns.user.id

    with :ok <- allow(zone, user_id),
         {:ok, slot} <- Slots.join(zone.id, user_id) do
      reply = %{
        desync_index_url: VSekai.get_desync_url_for_map(zone.map),
        slot: slot,
        slots: Slots.table(zone.id)
      }

      {:ok, reply, assign(socket, :zone_id, zone.id)}
    else
      {:error, :not_allowed} -> {:error, %{reason: "not allowed"}}
      {:error, :full} -> {:error, %{reason: "zone full"}}
    end
  rescue
    Ecto.NoResultsError -> {:error, %{reason: "zone not found"}}
  end

  # Runs when the client leaves and when its connection closes.
  def terminate(_reason, socket) do
    case socket.assigns do
      %{zone_id: zone_id, user: user} -> Slots.leave(zone_id, user.id)
      _ -> :ok
    end
  end

  defp allow(zone, user_id) do
    if VSekai.can_enter_zone?(zone, user_id), do: :ok, else: {:error, :not_allowed}
  end
end

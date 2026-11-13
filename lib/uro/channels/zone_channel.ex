# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.ZoneChannel do
  @moduledoc """
  The channel of one zone, `zone:<zone id>`.

  A client that joins receives the desync index URL immediately, with the slot it was
  given and the zone's four slots (user ids or nil). When the zone server sends a
  PUT /shards/:id heartbeat, zone-backend broadcasts "zone_updated" to all subscribers so
  clients fetch fresh chunks.

  A user for whom `Uro.VSekai.can_enter_zone?/2` is false is refused with "not allowed",
  and one who finds all four slots taken with "zone full". `terminate/2` runs when the
  client leaves and when its connection closes, and frees the slot.

  ## Pair keys

  Each pair of seated members shares one key (`Uro.Zones.PairKeys`). After a join or a
  leave has changed the table, every seated member is pushed `"pair_keys"`:

      %{keys: %{"1" => "<base64 of 32 bytes>", "2" => "<base64 of 32 bytes>"}}

  `keys` maps the slot of each other member, as a decimal string, to the key the receiver
  shares with that member. A member who is alone gets `%{keys: %{}}`. A key that was
  pushed before and is pushed again is unchanged; a slot that is no longer there means
  that pair's key is dropped.

  A key must never reach a member outside its pair, so no key is ever put in a broadcast.
  What is broadcast to the zone's topic is `"members_changed"` with an empty payload. The
  channel intercepts that event, so it is never sent to a client; each member's own channel
  process handles it in `handle_out/3`, asks `PairKeys.keys_for/2` for the keys of its own
  user, and pushes them on its own socket. The only path a key takes is from the key
  process to the channel process of a member of the pair, and from there to that member's
  socket. This needs no topic for each user and no list of channel processes, and a member
  who misses one broadcast is brought up to date by the next.

  The joining process is subscribed to the topic only after `join/3` returns, so it
  broadcasts from `handle_info(:after_join, ...)` and receives its own first keys the same
  way as the others. Nothing here logs a key: Phoenix logs the join and its params, not
  pushes.
  """
  use Uro, :channel

  alias Uro.VSekai
  alias Uro.Zones.PairKeys
  alias Uro.Zones.Slots

  @members_changed "members_changed"

  intercept [@members_changed]

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

      :ok = PairKeys.refresh(zone.id)
      send(self(), :after_join)
      {:ok, reply, assign(socket, :zone_id, zone.id)}
    else
      {:error, :not_allowed} -> {:error, %{reason: "not allowed"}}
      {:error, :full} -> {:error, %{reason: "zone full"}}
    end
  rescue
    Ecto.NoResultsError -> {:error, %{reason: "zone not found"}}
  end

  def handle_info(:after_join, socket) do
    broadcast(socket, @members_changed, %{})
    {:noreply, socket}
  end

  def handle_out(@members_changed, _payload, socket) do
    %{zone_id: zone_id, user: user} = socket.assigns

    keys =
      Map.new(PairKeys.keys_for(zone_id, user.id), fn {slot, key} ->
        {Integer.to_string(slot), Base.encode64(key)}
      end)

    push(socket, "pair_keys", %{keys: keys})
    {:noreply, socket}
  end

  def terminate(_reason, socket) do
    case socket.assigns do
      %{zone_id: zone_id, user: user} ->
        Slots.leave(zone_id, user.id)
        PairKeys.refresh(zone_id)
        broadcast_from(socket, @members_changed, %{})

      _ ->
        :ok
    end
  end

  defp allow(zone, user_id) do
    if VSekai.can_enter_zone?(zone, user_id), do: :ok, else: {:error, :not_allowed}
  end
end

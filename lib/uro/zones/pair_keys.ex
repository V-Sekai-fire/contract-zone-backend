# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Zones.PairKeys do
  @moduledoc """
  One secret key for each pair of users seated in a zone.

  A zone seats up to four users (`Uro.Zones.Slots`), so it has up to six pairs. Each
  unordered pair has one key of 32 random bytes from `:crypto.strong_rand_bytes/1`. The
  two members of a pair are the only ones who are given it.

  ## When keys change

  `refresh/2` reads the zone's table from `Uro.Zones.Slots` and brings the keys in line
  with it (`update/2`):

    * a pair whose two members are both still seated keeps its key, also when a third
      member joins or leaves;
    * a pair that lost a member is dropped with its key;
    * a pair that is new gets a new key. A pair that forms again after a leave is new, so
      it never gets its old key back.

  The caller refreshes after every join and leave. This process reads the table itself,
  inside the call, and does not take one from the caller: when two members join at the
  same moment, the refresh that runs last reads a table that has both, so a late call
  cannot put back an older table.

  ## What a member is given

  `keys_for/3` returns a map from the slot of each other member to the key the two share,
  and an empty map for a user who is not seated. It is the only function that returns
  keys, and it returns only keys of pairs the user is in. `Uro.ZoneChannel` calls it from
  the channel process of that one user (see its moduledoc for why no key is ever in a
  broadcast).

  ## Where keys are

  In the memory of this process only. They are not written to the database and the
  tables are empty after a restart, as the slots are. `format_status/1` takes the state
  out of what `:sys.get_status/1` and a crash report print, so a crash of this process
  does not put keys in the log. Nothing here logs.
  """

  use GenServer

  alias Uro.Zones.Slots

  @key_bytes 32

  @type key :: <<_::256>>
  @type pair :: {Slots.user_id(), Slots.user_id()}
  @type keys :: %{pair() => key()}

  @doc """
  The keys for `table`, given the keys there were: kept for the pairs that are still
  seated, made for the new pairs, and without the pairs that are gone. A pair is
  `{a, b}` with `a < b`, whichever slots the two hold.
  """
  @spec update(keys(), Slots.table()) :: keys()
  def update(keys, table) do
    seated = Enum.reject(table, &is_nil/1)

    for a <- seated, b <- seated, a < b, into: %{} do
      {{a, b}, Map.get_lazy(keys, {a, b}, fn -> :crypto.strong_rand_bytes(@key_bytes) end)}
    end
  end

  @doc """
  Starts the process. `:name` is its name (this module by default) and `:slots` is the
  `Uro.Zones.Slots` server whose tables it reads (that module by default).
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.get(opts, :slots, Slots), name: name)
  end

  @doc "Brings the keys of `zone_id` in line with its table as it is now."
  @spec refresh(Slots.zone_id(), GenServer.server()) :: :ok
  def refresh(zone_id, server \\ __MODULE__) do
    GenServer.call(server, {:refresh, zone_id})
  end

  @doc "The keys `user_id` shares with each other member of `zone_id`, by the other's slot."
  @spec keys_for(Slots.zone_id(), Slots.user_id(), GenServer.server()) :: %{Slots.slot() => key()}
  def keys_for(zone_id, user_id, server \\ __MODULE__) do
    GenServer.call(server, {:keys_for, zone_id, user_id})
  end

  @impl GenServer
  def init(slots), do: {:ok, %{slots: slots, zones: %{}}}

  @impl GenServer
  def handle_call({:refresh, zone_id}, _from, state) do
    table = Slots.table(zone_id, state.slots)
    {_table, keys} = Map.get(state.zones, zone_id, {table, %{}})

    zones =
      if Enum.all?(table, &is_nil/1),
        do: Map.delete(state.zones, zone_id),
        else: Map.put(state.zones, zone_id, {table, update(keys, table)})

    {:reply, :ok, %{state | zones: zones}}
  end

  def handle_call({:keys_for, zone_id, user_id}, _from, state) do
    {table, keys} = Map.get(state.zones, zone_id, {[], %{}})

    reply =
      if user_id in table do
        for {other, slot} <- Enum.with_index(table), other != nil, other != user_id, into: %{} do
          {slot, Map.fetch!(keys, pair(user_id, other))}
        end
      else
        %{}
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def format_status(status), do: Map.replace(status, :state, :not_shown)

  defp pair(a, b) when a < b, do: {a, b}
  defp pair(a, b), do: {b, a}
end

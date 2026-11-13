# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Zones.Slots do
  @moduledoc """
  The four slots of a zone.

  A table is a list of four entries, each a user id or `nil`; the index is the slot number.
  `new/0`, `seat/2` and `vacate/2` are pure functions over a table. The process holds one
  table per zone id in memory, so the tables are empty after a restart. A table that
  becomes empty is dropped, so the process does not keep an entry for every zone ever
  joined.
  """

  use GenServer

  @slots 4

  @type user_id :: term()
  @type zone_id :: term()
  @type slot :: 0..3
  @type table :: [user_id() | nil]

  @spec new() :: table()
  def new, do: List.duplicate(nil, @slots)

  @doc """
  Seats `user_id` in the lowest free slot. A user who is already seated keeps their slot.
  """
  @spec seat(table(), user_id()) :: {:ok, slot(), table()} | {:error, :full}
  def seat(table, user_id) when not is_nil(user_id) do
    case Enum.find_index(table, &(&1 == user_id)) do
      nil ->
        case Enum.find_index(table, &is_nil/1) do
          nil -> {:error, :full}
          slot -> {:ok, slot, List.replace_at(table, slot, user_id)}
        end

      slot ->
        {:ok, slot, table}
    end
  end

  @doc "Frees the slot `user_id` holds, if any."
  @spec vacate(table(), user_id()) :: table()
  def vacate(table, user_id) when not is_nil(user_id) do
    Enum.map(table, fn seated -> if seated == user_id, do: nil, else: seated end)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec join(zone_id(), user_id(), GenServer.server()) :: {:ok, slot()} | {:error, :full}
  def join(zone_id, user_id, server \\ __MODULE__) do
    GenServer.call(server, {:join, zone_id, user_id})
  end

  @spec leave(zone_id(), user_id(), GenServer.server()) :: :ok
  def leave(zone_id, user_id, server \\ __MODULE__) do
    GenServer.call(server, {:leave, zone_id, user_id})
  end

  @spec table(zone_id(), GenServer.server()) :: table()
  def table(zone_id, server \\ __MODULE__) do
    GenServer.call(server, {:table, zone_id})
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:join, zone_id, user_id}, _from, tables) do
    case seat(Map.get(tables, zone_id, new()), user_id) do
      {:ok, slot, table} -> {:reply, {:ok, slot}, Map.put(tables, zone_id, table)}
      {:error, :full} -> {:reply, {:error, :full}, tables}
    end
  end

  def handle_call({:leave, zone_id, user_id}, _from, tables) do
    table = vacate(Map.get(tables, zone_id, new()), user_id)

    tables =
      if table == new(), do: Map.delete(tables, zone_id), else: Map.put(tables, zone_id, table)

    {:reply, :ok, tables}
  end

  def handle_call({:table, zone_id}, _from, tables) do
    {:reply, Map.get(tables, zone_id, new()), tables}
  end
end

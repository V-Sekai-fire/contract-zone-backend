# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Zones.SlotsTest do
  @moduledoc """
  A zone seats four users. The table is plain data; the process holds one table per zone.
  Nothing here touches the Repo: the process under test is started by the test itself.
  """
  use ExUnit.Case, async: true

  alias Uro.Zones.Slots

  describe "the table (pure)" do
    test "a new table has four empty slots" do
      assert Slots.new() == [nil, nil, nil, nil]
    end

    test "users are seated in the lowest free slot" do
      {:ok, 0, table} = Slots.seat(Slots.new(), "a")
      {:ok, 1, table} = Slots.seat(table, "b")
      assert table == ["a", "b", nil, nil]
    end

    test "seating a user twice returns the same slot and changes nothing" do
      {:ok, 0, table} = Slots.seat(Slots.new(), "a")
      {:ok, 1, table} = Slots.seat(table, "b")
      assert {:ok, 1, ^table} = Slots.seat(table, "b")
    end

    test "control: a fifth user is refused" do
      table = Enum.reduce(~w(a b c d), Slots.new(), fn u, t -> elem(Slots.seat(t, u), 2) end)
      assert table == ~w(a b c d)
      assert Slots.seat(table, "e") == {:error, :full}
    end

    test "vacating frees the slot for the next user and keeps the others in place" do
      table = Enum.reduce(~w(a b c d), Slots.new(), fn u, t -> elem(Slots.seat(t, u), 2) end)
      table = Slots.vacate(table, "b")
      assert table == ["a", nil, "c", "d"]
      assert {:ok, 1, ["a", "e", "c", "d"]} = Slots.seat(table, "e")
    end

    test "vacating a user who is not seated changes nothing" do
      {:ok, 0, table} = Slots.seat(Slots.new(), "a")
      assert Slots.vacate(table, "nobody") == table
    end
  end

  describe "the process (one table per zone id)" do
    setup do
      name = :"slots_#{System.unique_integer([:positive])}"
      start_supervised!({Slots, name: name})
      %{slots: name}
    end

    test "join seats, is idempotent, and table shows the four slots", %{slots: s} do
      assert Slots.join("z", "a", s) == {:ok, 0}
      assert Slots.join("z", "b", s) == {:ok, 1}
      assert Slots.join("z", "a", s) == {:ok, 0}
      assert Slots.table("z", s) == ["a", "b", nil, nil]
    end

    test "control: the fifth join is refused and the table is unchanged", %{slots: s} do
      for {u, i} <- Enum.with_index(~w(a b c d)), do: assert(Slots.join("z", u, s) == {:ok, i})
      assert Slots.join("z", "e", s) == {:error, :full}
      assert Slots.table("z", s) == ~w(a b c d)
    end

    test "leave frees the slot", %{slots: s} do
      {:ok, 0} = Slots.join("z", "a", s)
      assert Slots.leave("z", "a", s) == :ok
      assert Slots.table("z", s) == [nil, nil, nil, nil]
    end

    test "zones do not share a table", %{slots: s} do
      {:ok, 0} = Slots.join("z1", "a", s)
      assert Slots.join("z2", "b", s) == {:ok, 0}
      assert Slots.table("z1", s) == ["a", nil, nil, nil]
      assert Slots.table("z2", s) == ["b", nil, nil, nil]
    end

    test "a zone nobody joined has an empty table", %{slots: s} do
      assert Slots.table("never", s) == [nil, nil, nil, nil]
    end
  end
end

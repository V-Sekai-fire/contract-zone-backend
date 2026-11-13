# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Zones.SlotsPropertyTest do
  @moduledoc """
  Random sequences of joins and leaves by a pool of users against one zone.

  PropCheck is not a dependency of this project, so the sequences come from `:rand` with a
  seed that is printed when a sequence fails. There is no shrinking. Nothing here touches
  the Repo.

  The pool has more users than slots and there are two joins for each leave, so tables
  fill and the fifth join is reached often; the test fails if no sequence was refused,
  because a property that never fills a table proves little.

  After every step the table must be a valid seating: four entries (so at most four are
  seated and no slot holds two users) and no user in two slots.
  """
  use ExUnit.Case, async: true

  alias Uro.Zones.Slots

  @runs 500
  @max_steps 60
  @pool ~w(u1 u2 u3 u4 u5 u6 u7)

  setup do
    name = :"slots_property_#{System.unique_integer([:positive])}"
    start_supervised!({Slots, name: name})
    %{slots: name}
  end

  test "after any joins and leaves the table is a valid seating", %{slots: s} do
    seed = :rand.uniform(4_294_967_296)
    state = :rand.seed_s(:exsss, seed)

    {_state, full_refusals} =
      Enum.reduce(1..@runs, {state, 0}, fn run, {state, refusals} ->
        zone = "zone-#{run}"
        {steps, state} = gen_steps(state)

        refusals =
          Enum.reduce(steps, refusals, fn step, refusals ->
            before = Slots.table(zone, s)
            reply = apply_step(step, zone, s)
            table = Slots.table(zone, s)
            context = "seed #{seed}, run #{run}, step #{inspect(step)}, before #{inspect(before)}"

            assert_valid(table, context)
            assert_step(step, before, reply, table, context)
            if reply == {:error, :full}, do: refusals + 1, else: refusals
          end)

        {state, refusals}
      end)

    assert full_refusals > 0, "no sequence reached a full table (seed #{seed})"
  end

  defp gen_steps(state) do
    {n, state} = :rand.uniform_s(@max_steps, state)

    Enum.map_reduce(1..n, state, fn _, state ->
      {kind, state} = :rand.uniform_s(3, state)
      {user, state} = :rand.uniform_s(length(@pool), state)
      {{if(kind == 3, do: :leave, else: :join), Enum.at(@pool, user - 1)}, state}
    end)
  end

  defp apply_step({:join, user}, zone, s), do: Slots.join(zone, user, s)
  defp apply_step({:leave, user}, zone, s), do: Slots.leave(zone, user, s)

  defp assert_valid(table, context) do
    assert length(table) == 4, "the table has not four slots: #{inspect(table)} (#{context})"
    seated = Enum.reject(table, &is_nil/1)
    assert seated == Enum.uniq(seated), "a user holds two slots: #{inspect(table)} (#{context})"
    assert Enum.all?(seated, &(&1 in @pool)), "an unknown user is seated: #{inspect(table)}"
  end

  defp assert_step({:join, user}, before, reply, table, context) do
    cond do
      user in before ->
        slot = Enum.find_index(before, &(&1 == user))
        assert reply == {:ok, slot}, "a seated user changed slot: #{inspect(reply)} (#{context})"
        assert table == before, "a repeated join changed the table (#{context})"

      nil in before ->
        assert {:ok, slot} = reply, "a join with a free slot was refused (#{context})"
        assert Enum.at(before, slot) == nil, "a join took a slot that was held (#{context})"
        assert table == List.replace_at(before, slot, user), "a join moved someone (#{context})"

      true ->
        assert reply == {:error, :full}, "a join when full was not refused (#{context})"
        assert table == before, "a refused join changed the table (#{context})"
    end
  end

  defp assert_step({:leave, user}, before, reply, table, context) do
    assert reply == :ok
    refute user in table, "a user who left is still seated (#{context})"

    assert table == Enum.map(before, &if(&1 == user, do: nil, else: &1)),
           "a leave moved someone else (#{context})"
  end
end

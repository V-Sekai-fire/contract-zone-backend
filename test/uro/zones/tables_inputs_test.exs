# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Zones.TablesInputsTest do
  @moduledoc """
  `Uro.Zones.Tables.inputs/2` gathers what the encoders need from the slots of a zone and
  the stored tuples, and these tests read the tables it leads to.

  Each test starts its own `Uro.Zones.Slots` and `Uro.Zones.PairKeys`, so the processes
  of the application are not touched; the tuples are in the Repo.

  The controls are written as tests that a failure is detected: a grant on another zone
  or on a bare user id sets no flag; a member table with one slot planted wrong is not
  the table the tuples give; a keys table handed to the wrong slot is not what
  `Uro.Zones.PairKeys.keys_for/3` gives that slot.

  The property seats seeded random members with random grants and checks that no key of
  the zone is in the router table or the member table, and that the keys table of a slot
  has the keys of that slot's pairs and of no other pair. It fails if no zone had a pair
  that some member was not in. PropCheck is not a dependency of this project, so the
  zones come from `:rand` with a seed that is printed on failure.
  """
  use Uro.RepoCase, async: false

  alias Uro.Tuples
  alias Uro.Tuples.Tuple
  alias Uro.Zones.PairKeys
  alias Uro.Zones.Slots
  alias Uro.Zones.Tables

  @runs 200
  @pool ~w(u1 u2 u3 u4 u5 u6)

  setup do
    n = System.unique_integer([:positive])
    slots = :"tables_slots_#{n}"
    keys = :"tables_keys_#{n}"
    start_supervised!({Slots, name: slots})
    start_supervised!({PairKeys, name: keys, slots: slots})
    %{slots: slots, keys: keys}
  end

  defp seat(users, zone, %{slots: s, keys: k}) do
    for user <- users, do: {:ok, _} = Slots.join(zone, user, s)
    :ok = PairKeys.refresh(zone, k)
  end

  defp tables(zone, ctx, ranges \\ []) do
    {:ok, inputs} = Tables.inputs(zone, slots: ctx.slots, ranges: ranges)

    {Tables.router_table(inputs.slots, inputs.sees),
     Tables.member_table(inputs.slots, inputs.controls)}
  end

  defp grant_all(users, zone) do
    for user <- users, do: {:ok, _} = Tuples.put(user, "SEND", zone)

    for viewer <- users, sender <- users, viewer != sender do
      {:ok, _} = Tuples.put(viewer, "SEES", Tables.avatar_object(sender))
    end
  end

  test "the inputs are the seats with their numbers, grants and epochs", ctx do
    seat(~w(a b), "z", ctx)
    {:ok, _} = Tuples.put("a", "SEND", "z")
    {:ok, _} = Tuples.put("b", "SEES", "avatar:a")
    {:ok, _} = Tuples.replace("CONTROLS", "avatar:b", "b")
    {:ok, _} = Tuples.replace("CONTROLS", "avatar:b", "b")
    {:ok, _} = Tuples.replace("CONTROLS", "ball-7", "b")
    ranges = [{"ball-7", 100, 199}, {"ball-8", 200, 200}]

    assert Tables.inputs("z", slots: ctx.slots, ranges: ranges) ==
             {:ok,
              %{
                slots: [
                  %{user: "a", number: Tables.user_number("a"), send: true, epoch: 0},
                  %{user: "b", number: Tables.user_number("b"), send: false, epoch: 2},
                  nil,
                  nil
                ],
                sees: MapSet.new([{"b", "a"}]),
                controls: [
                  %{first_gid: 100, last_gid: 199, controller: "b", epoch: 1},
                  %{first_gid: 200, last_gid: 200, controller: nil, epoch: 0}
                ]
              }}
  end

  test "a zone id that is an integer names its tuples by its decimal string", ctx do
    seat(~w(a), 41, ctx)
    {:ok, _} = Tuples.put("a", "SEND", "41")

    assert {:ok, %{slots: [%{user: "a", send: true}, nil, nil, nil]}} =
             Tables.inputs(41, slots: ctx.slots)
  end

  test "control: when B does not see A, only row B, column A differs from all-see", ctx do
    users = ~w(a b c d)
    seat(users, "z", ctx)
    grant_all(users, "z")
    {all_see, _member} = tables("z", ctx)

    assert all_see == <<1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0>>

    {:ok, 1} = Tuples.delete("b", "SEES", "avatar:a")
    {table, _member} = tables("z", ctx)

    assert table == <<1, 1, 1, 1, 0, 1, 1, 1, 0, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0>>
    assert :binary.at(table, 4 + 1 * 4 + 0) == 0
  end

  test "control: a grant on another zone, on a bare user id or to nobody seated sets nothing",
       ctx do
    seat(~w(a b), "z", ctx)
    {:ok, _} = Tuples.put("a", "SEND", "other")
    {:ok, _} = Tuples.put("a", "SEES", "b")
    {:ok, _} = Tuples.put("a", "SEES", "avatar:a")
    {:ok, _} = Tuples.put("stranger", "SEES", "avatar:a")
    {:ok, _} = Tuples.put("stranger", "SEND", "z")

    assert {router, _member} = tables("z", ctx)
    assert router == <<0::160>>
  end

  test "control: a member table with one slot planted wrong is not what the tuples give",
       ctx do
    seat(~w(a b c), "z", ctx)
    {:ok, _} = Tuples.replace("CONTROLS", "ball-7", "a")
    {:ok, _} = Tuples.replace("CONTROLS", "ball-7", "c")
    ranges = [{"ball-7", 100, 199}]

    {_router, member} = tables("z", ctx, ranges)
    {:ok, rows} = Tables.decode_member_table(member)
    assert hd(rows) == %{first_gid: 100, last_gid: 199, slot: 2, epoch: 2}
    assert length(rows) == 4

    planted =
      <<4, 0, 100::32-little, 199::32-little, 0>> <>
        binary_part(member, 11, byte_size(member) - 11)

    assert byte_size(planted) == byte_size(member)
    assert {:ok, planted_rows} = Tables.decode_member_table(planted)
    refute planted_rows == rows
    refute planted == member

    {:ok, _} = Tuples.replace("CONTROLS", "ball-7", "a")
    {_router, handed_back} = tables("z", ctx, ranges)
    refute handed_back == planted
    assert {:ok, [%{slot: 0, epoch: 3} | _]} = Tables.decode_member_table(handed_back)

    :ok = Slots.leave("z", "a", ctx.slots)
    {_router, left} = tables("z", ctx, ranges)
    assert {:ok, [%{slot: 255, epoch: 3} | bodies]} = Tables.decode_member_table(left)
    assert Enum.map(bodies, & &1.slot) |> Enum.sort() == [1, 2]
  end

  test "control: ranges that share an entity id are an error, not a table", ctx do
    seat(~w(a), "z", ctx)
    {first, last} = Tables.body_range(Tables.user_number("a"))

    assert {:error, {:overlap, _, _}} =
             Tables.inputs("z", slots: ctx.slots, ranges: [{"x", 1, 5}, {"y", 5, 9}])

    assert {:error, {:overlap, _, _}} =
             Tables.inputs("z", slots: ctx.slots, ranges: [{"x", last, last + 1}])

    assert {:error, {:out_of_range, _}} =
             Tables.inputs("z", slots: ctx.slots, ranges: [{"x", first - 1, 4_294_967_296}])
  end

  test "control: a keys table handed to the wrong slot is not that slot's keys", ctx do
    seat(~w(a b c), "z", ctx)
    held = Map.new(~w(a b c), fn user -> {user, PairKeys.keys_for("z", user, ctx.keys)} end)
    files = Map.new(held, fn {user, keys} -> {user, Tables.keys_table(keys)} end)

    for owner <- ~w(a b c), reader <- ~w(a b c) do
      {:ok, keys} = Tables.decode_keys_table(files[owner])
      assert keys == held[reader] == (owner == reader)
    end
  end

  test "no key of the zone is in the router or member table, and each keys table has its own",
       ctx do
    seed = :rand.uniform(4_294_967_296)

    {_state, others} =
      Enum.reduce(1..@runs, {:rand.seed_s(:exsss, seed), 0}, fn run, {state, others} ->
        Repo.delete_all(Tuple)
        zone = "zone-#{run}"
        {users, state} = gen_zone(zone, state)
        seat(users, zone, ctx)
        context = "seed #{seed}, run #{run}, users #{inspect(users)}"

        {router, member} = tables(zone, ctx, [{"ball-7", 100, 199}])
        table = Slots.table(zone, ctx.slots)
        held = for user <- users, into: %{}, do: {user, PairKeys.keys_for(zone, user, ctx.keys)}
        all = held |> Map.values() |> Enum.flat_map(&Map.values/1) |> Enum.uniq()

        assert length(all) == div(length(users) * (length(users) - 1), 2), context

        for key <- all, {name, bytes} <- [{"router", router}, {"member", member}] do
          assert :binary.match(bytes, key) == :nomatch,
                 "a key is in the #{name} table (#{context})"
        end

        foreign =
          for {user, slot} <- Enum.with_index(table), user != nil do
            file = Tables.keys_table(held[user])
            own = Map.values(held[user])

            assert Tables.decode_keys_table(file) == {:ok, held[user]},
                   "keys.#{slot}.table is not the keys of slot #{slot} (#{context})"

            for key <- own do
              assert length(:binary.matches(file, key)) == 1,
                     "keys.#{slot}.table does not have a key of slot #{slot} once (#{context})"
            end

            for key <- all -- own do
              assert :binary.match(file, key) == :nomatch,
                     "keys.#{slot}.table has the key of another pair (#{context})"
            end

            length(all -- own)
          end

        {state, others + Enum.sum(foreign)}
      end)

    assert others > 0, "no zone had a pair that some member was not in (seed #{seed})"
  end

  defp gen_zone(zone, state) do
    {count, state} = :rand.uniform_s(4, state)
    {keyed, state} = Enum.map_reduce(@pool, state, fn u, s -> swap(:rand.uniform_s(s), u) end)
    users = keyed |> Enum.sort() |> Enum.take(count) |> Enum.map(&elem(&1, 1))

    grants =
      [{"ball-owner", "CONTROLS", "ball-7"}] ++
        for(u <- users, do: {u, "SEND", zone}) ++
        for(v <- users, s <- users, do: {v, "SEES", Tables.avatar_object(s)}) ++
        for(u <- users, do: {u, "CONTROLS", "ball-7"})

    state =
      Enum.reduce(grants, state, fn {subject, verb, object}, state ->
        {keep, state} = :rand.uniform_s(2, state)
        if keep == 1, do: {:ok, _} = Tuples.put(subject, verb, object)
        state
      end)

    {users, state}
  end

  defp swap({key, state}, x), do: {{key, x}, state}
end

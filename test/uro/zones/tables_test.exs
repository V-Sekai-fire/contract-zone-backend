# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Zones.TablesTest do
  @moduledoc """
  The encoders and decoders of `Uro.Zones.Tables`, which are pure, so nothing here touches
  the Repo or a process.

  Each property makes seeded random inputs and compares what the decoder gives for the
  encoded bytes with a model the test computes on its own from the same inputs. The slot
  tables have empty slots, the `sees` sets have pairs of a user with itself and pairs with
  users who are not seated, and the controls have controllers who are not seated, so the
  model must leave those out as the encoder must.

  PropCheck is not a dependency of this project, so the inputs come from `:rand` with a
  seed that is printed on failure. There is no shrinking.
  """
  use ExUnit.Case, async: true

  alias Uro.Zones.Tables

  @runs 400
  @pool ~w(u1 u2 u3 u4 u5 u6)

  describe "router_table/2" do
    test "a zone of two, where slot 0 may send and slot 2 sees slot 0, byte by byte" do
      slots = [seat("a", 7, send: true), nil, seat("b", 9), nil]

      assert Tables.router_table(slots, MapSet.new([{"b", "a"}])) ==
               <<1, 0, 0, 0>> <>
                 <<0, 0, 0, 0>> <>
                 <<0, 0, 0, 0>> <>
                 <<1, 0, 0, 0>> <>
                 <<0, 0, 0, 0>>
    end

    test "is 20 bytes for every input, and decodes to the model" do
      seed = :rand.uniform(4_294_967_296)

      {_state, {seen, empty}} =
        Enum.reduce(1..@runs, {:rand.seed_s(:exsss, seed), {0, 0}}, fn run, {state, {n, e}} ->
          {slots, state} = gen_slots(state)
          {sees, state} = gen_sees(state)
          context = "seed #{seed}, run #{run}, slots #{inspect(slots)}, sees #{inspect(sees)}"

          table = Tables.router_table(slots, sees)
          assert byte_size(table) == 20, "the router table is not 20 bytes (#{context})"

          model = router_model(slots, sees)
          assert Tables.decode_router_table(table) == {:ok, model}, "not the model (#{context})"

          for slot <- 0..3 do
            assert :binary.at(table, 4 + slot * 5) == 0, "the diagonal is not 0 (#{context})"
          end

          {state, {n + MapSet.size(model.sees), e + Enum.count(slots, &is_nil/1)}}
        end)

      assert seen > 0, "no table had a pair that sees (seed #{seed})"
      assert empty > 0, "no table had an empty slot (seed #{seed})"
    end

    test "control: when B does not see A, only row B, column A differs from all-see" do
      slots = for {user, n} <- Enum.with_index(~w(a b c d)), do: seat(user, n, send: true)
      everyone = for v <- ~w(a b c d), s <- ~w(a b c d), into: MapSet.new(), do: {v, s}
      all_see = Tables.router_table(slots, everyone)

      for {viewer, row} <- Enum.with_index(~w(a b c d)),
          {sender, column} <- Enum.with_index(~w(a b c d)),
          viewer != sender do
        table = Tables.router_table(slots, MapSet.delete(everyone, {viewer, sender}))
        at = 4 + row * 4 + column

        assert :binary.at(all_see, at) == 1
        assert :binary.at(table, at) == 0
        assert binary_part(table, 0, at) == binary_part(all_see, 0, at)
        assert binary_part(table, at + 1, 19 - at) == binary_part(all_see, at + 1, 19 - at)
      end
    end

    test "control: a seat without the send grant, and a pair with an empty slot, give 0" do
      slots = [seat("a", 1, send: false), seat("b", 2, send: true), nil, nil]
      sees = MapSet.new([{"a", "b"}, {"a", "c"}, {"c", "a"}, {"a", "a"}])

      assert {:ok, %{send: [false, true, false, false], sees: pairs}} =
               Tables.decode_router_table(Tables.router_table(slots, sees))

      assert pairs == MapSet.new([{0, 1}])
    end

    test "control: the decoder refuses a wrong size, a byte above 1 and a set diagonal" do
      good = Tables.router_table([seat("a", 1), seat("b", 2), nil, nil], MapSet.new())
      assert {:ok, _} = Tables.decode_router_table(good)

      assert Tables.decode_router_table(binary_part(good, 0, 19)) == {:error, :malformed}
      assert Tables.decode_router_table(good <> <<0>>) == {:error, :malformed}
      assert Tables.decode_router_table(put_byte(good, 5, 2)) == {:error, :malformed}
      assert Tables.decode_router_table(put_byte(good, 9, 1)) == {:error, :malformed}
    end
  end

  describe "user_number/1, avatar_object/1 and body_range/1" do
    test "the number of a user is the first four bytes of the SHA-256 of its id, reduced" do
      assert Tables.user_number("544ac5ad-1f6c-4a15-9375-3e1bd66045e1") == 112_914_882
      assert Tables.user_number("u1") == 79_454_643
      assert Tables.avatar_object("u1") == "avatar:u1"
    end

    test "the body of a user number is 21 entity ids from 2_000_000 + 21 * number" do
      assert Tables.body_range(0) == {2_000_000, 2_000_020}
      assert Tables.body_range(7) == {2_000_147, 2_000_167}
      assert Tables.body_range(8) == {2_000_168, 2_000_188}
    end

    test "the highest user number keeps the body below 2^32, and the next does not" do
      max = Tables.max_user_number()
      assert max * 21 + 2_000_000 + 20 < 4_294_967_296
      assert (max + 1) * 21 + 2_000_000 + 20 >= 4_294_967_296

      seed = :rand.uniform(4_294_967_296)

      Enum.reduce(1..@runs, :rand.seed_s(:exsss, seed), fn _, state ->
        {bytes, state} = :rand.bytes_s(16, state)
        id = Base.encode16(bytes, case: :lower)
        number = Tables.user_number(id)

        assert number in 0..max, "the number of #{id} is #{number} (seed #{seed})"
        assert Tables.user_number(id) == number
        state
      end)
    end
  end

  describe "member_table/2" do
    test "a zone of two with one further range, byte by byte" do
      slots = [seat("a", 7, epoch: 3), nil, seat("b", 9), nil]

      controls = [
        %{first_gid: 100, last_gid: 199, controller: "b", epoch: 258},
        %{first_gid: 4_000_000, last_gid: 4_000_000, controller: "gone", epoch: 1}
      ]

      assert Tables.member_table(slots, controls) ==
               <<4, 0>> <>
                 <<100::32-little, 199::32-little, 2, 2, 1, 0, 0>> <>
                 <<2_000_147::32-little, 2_000_167::32-little, 0, 3, 0, 0, 0>> <>
                 <<2_000_189::32-little, 2_000_209::32-little, 2, 0, 0, 0, 0>> <>
                 <<4_000_000::32-little, 4_000_000::32-little, 255, 1, 0, 0, 0>>
    end

    test "is 2 + 13 * rows bytes, sorted, and decodes to the model" do
      seed = :rand.uniform(4_294_967_296)

      {_state, {seated, absent}} =
        Enum.reduce(1..@runs, {:rand.seed_s(:exsss, seed), {0, 0}}, fn run, {state, {n, a}} ->
          {slots, state} = gen_slots(state)
          {controls, state} = gen_controls(state)
          context = "seed #{seed}, run #{run}, slots #{inspect(slots)}, #{inspect(controls)}"

          table = Tables.member_table(slots, controls)
          model = member_model(slots, controls)

          assert byte_size(table) == 2 + 13 * length(model), "the size is wrong (#{context})"
          assert Tables.decode_member_table(table) == {:ok, model}, "not the model (#{context})"

          further = Enum.reject(model, &(&1.first_gid >= 2_000_000))
          gone = Enum.count(further, &(&1.slot == 255))
          {state, {n + length(further) - gone, a + gone}}
        end)

      assert seated > 0, "no further range had a seated controller (seed #{seed})"
      assert absent > 0, "no further range had a controller who is not seated (seed #{seed})"
    end

    test "an empty zone has no row" do
      assert Tables.member_table([nil, nil, nil, nil], []) == <<0, 0>>
      assert Tables.decode_member_table(<<0, 0>>) == {:ok, []}
    end

    test "control: a slot planted wrong in one row is not the table the inputs give" do
      slots = [seat("a", 7), seat("b", 9), nil, nil]
      controls = [%{first_gid: 100, last_gid: 199, controller: "b", epoch: 4}]
      table = Tables.member_table(slots, controls)
      {:ok, rows} = Tables.decode_member_table(table)

      for row <- 0..2, planted <- [0, 1, 2, 3, 255] do
        changed = put_byte(table, 2 + 13 * row + 8, planted)

        if changed == table do
          assert Enum.at(rows, row).slot == planted
        else
          assert {:ok, other} = Tables.decode_member_table(changed)
          assert other != rows
          assert List.delete_at(other, row) == List.delete_at(rows, row)
          assert Enum.at(other, row) == %{Enum.at(rows, row) | slot: planted}
        end
      end
    end

    test "control: ranges that overlap and values that do not fit are refused" do
      slots = [seat("a", 7), nil, nil, nil]
      range = fn first, last -> %{first_gid: first, last_gid: last, controller: "a", epoch: 0} end

      for controls <- [
            [range.(100, 199), range.(199, 300)],
            [range.(2_000_167, 2_000_168)],
            [range.(5, 4)],
            [range.(0, 4_294_967_296)],
            [range.(-1, 4)],
            [%{range.(1, 2) | epoch: 4_294_967_296}]
          ] do
        assert_raise ArgumentError, fn -> Tables.member_table(slots, controls) end
      end

      for number <- [-1, Tables.max_user_number() + 1] do
        assert_raise ArgumentError, fn ->
          Tables.member_table([seat("a", number), nil, nil, nil], [])
        end
      end

      same = [seat("a", 7), seat("b", 7), nil, nil]
      assert_raise ArgumentError, fn -> Tables.member_table(same, []) end
    end

    test "control: the decoder refuses a table that is cut, padded, unsorted or malformed" do
      row = fn first, last, slot -> <<first::32-little, last::32-little, slot, 0::32>> end
      good = <<2, 0>> <> row.(1, 5, 0) <> row.(6, 9, 255)
      assert {:ok, [_, _]} = Tables.decode_member_table(good)

      for bad <- [
            <<>>,
            <<0>>,
            binary_part(good, 0, byte_size(good) - 1),
            good <> <<0>>,
            <<3, 0>> <> binary_part(good, 2, 26),
            <<1, 0>> <> binary_part(good, 2, 26),
            <<2, 0>> <> row.(6, 9, 0) <> row.(1, 5, 0),
            <<2, 0>> <> row.(1, 6, 0) <> row.(6, 9, 0),
            <<1, 0>> <> row.(5, 4, 0),
            <<1, 0>> <> row.(1, 5, 4),
            <<1, 0>> <> row.(1, 5, 254)
          ] do
        assert Tables.decode_member_table(bad) == {:error, :malformed}, inspect(bad)
      end
    end
  end

  defp seat(user, number, opts \\ []) do
    %{
      user: user,
      number: number,
      send: Keyword.get(opts, :send, false),
      epoch: Keyword.get(opts, :epoch, 0)
    }
  end

  defp put_byte(binary, at, byte) do
    binary_part(binary, 0, at) <>
      <<byte>> <> binary_part(binary, at + 1, byte_size(binary) - at - 1)
  end

  defp gen_slots(state) do
    {users, state} = shuffle(@pool, state)

    users
    |> Enum.take(4)
    |> Enum.map_reduce(state, fn user, state ->
      {kind, state} = :rand.uniform_s(3, state)
      {number, state} = :rand.uniform_s(1000, state)
      {send, state} = :rand.uniform_s(2, state)
      {epoch, state} = :rand.uniform_s(4_294_967_296, state)
      seat = seat(user, number * 1000 + user_index(user), send: send == 1, epoch: epoch - 1)
      {if(kind == 3, do: nil, else: seat), state}
    end)
  end

  defp gen_sees(state) do
    pairs = for viewer <- @pool, sender <- @pool, do: {viewer, sender}

    {kept, state} =
      Enum.map_reduce(pairs, state, fn pair, state ->
        {keep, state} = :rand.uniform_s(2, state)
        {{pair, keep == 1}, state}
      end)

    {for({pair, true} <- kept, into: MapSet.new(), do: pair), state}
  end

  defp shuffle(list, state) do
    {keyed, state} = Enum.map_reduce(list, state, fn x, s -> swap(:rand.uniform_s(s), x) end)
    {keyed |> Enum.sort() |> Enum.map(&elem(&1, 1)), state}
  end

  defp swap({key, state}, x), do: {{key, x}, state}

  defp user_index(user), do: Enum.find_index(@pool, &(&1 == user))

  defp slot_of(slots, user), do: Enum.find_index(slots, &(&1 != nil and &1.user == user))

  defp router_model(slots, sees) do
    pairs =
      for {viewer, sender} <- sees,
          viewer != sender,
          row = slot_of(slots, viewer),
          column = slot_of(slots, sender),
          into: MapSet.new(),
          do: {row, column}

    %{send: Enum.map(slots, &(&1 != nil and &1.send)), sees: pairs}
  end

  defp gen_controls(state) do
    {blocks, state} = shuffle(Enum.to_list(0..39), state)
    {count, state} = :rand.uniform_s(6, state)

    blocks
    |> Enum.take(count - 1)
    |> Enum.map_reduce(state, fn block, state ->
      {length, state} = :rand.uniform_s(100, state)
      {who, state} = :rand.uniform_s(length(@pool) + 1, state)
      {epoch, state} = :rand.uniform_s(4_294_967_296, state)
      first = if rem(block, 2) == 0, do: block * 100, else: 4_294_967_196 - block * 100

      {%{
         first_gid: first,
         last_gid: first + length - 1,
         controller: Enum.at(@pool, who - 1),
         epoch: epoch - 1
       }, state}
    end)
  end

  defp member_model(slots, controls) do
    bodies =
      for {seat, slot} <- Enum.with_index(slots), seat != nil do
        first = 2_000_000 + seat.number * 21
        %{first_gid: first, last_gid: first + 20, slot: slot, epoch: seat.epoch}
      end

    further =
      for c <- controls do
        slot = c.controller && slot_of(slots, c.controller)
        %{first_gid: c.first_gid, last_gid: c.last_gid, slot: slot || 255, epoch: c.epoch}
      end

    Enum.sort_by(bodies ++ further, & &1.first_gid)
  end
end

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
end

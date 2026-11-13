# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Zones.PairKeysTest do
  @moduledoc """
  `Uro.Zones.PairKeys` holds one key for each pair of users seated in a zone.

  The first part is the pure function over a table. The second starts its own
  `Uro.Zones.Slots` and `Uro.Zones.PairKeys`, so nothing here touches the Repo or the
  processes of the application.

  The property runs seeded random joins and leaves by a pool of seven users, with two
  joins for each leave so that tables fill, and after every step checks all of:

    * every pair of seated users has a key of 32 bytes, and both members get the same one;
    * a member gets a key for each other member's slot and for no other slot;
    * no two pairs share a key, so nobody holds the key of a pair they are not in;
    * a user who is not seated gets nothing;
    * a pair that stayed seated has the key it had;
    * a pair that is new, or that forms again after one of them left, has a key that was
      never used before.

  It fails if no pair kept a key or no pair formed again, because a property that never
  reaches those cases proves little. PropCheck is not a dependency of this project, so the
  sequences come from `:rand` with a seed that is printed on failure. There is no
  shrinking.
  """
  use ExUnit.Case, async: true

  alias Uro.Zones.PairKeys
  alias Uro.Zones.Slots

  @runs 500
  @max_steps 60
  @pool ~w(u1 u2 u3 u4 u5 u6 u7)

  describe "update/2 (pure)" do
    test "one user alone has no pair, two have one, four have six" do
      assert PairKeys.update(%{}, ["a", nil, nil, nil]) == %{}
      assert %{{"a", "b"} => <<_::binary-size(32)>>} = PairKeys.update(%{}, ["a", "b", nil, nil])
      assert map_size(PairKeys.update(%{}, ~w(a b c d))) == 6
    end

    test "a pair is one pair whichever slots its members hold" do
      keys = PairKeys.update(%{}, ["b", nil, "a", nil])
      assert Map.keys(keys) == [{"a", "b"}]
      assert PairKeys.update(keys, ["a", "b", nil, nil]) == keys
    end

    test "a pair that stays keeps its key, and a pair that broke is dropped" do
      keys = PairKeys.update(%{}, ["a", "b", "c", nil])
      after_leave = PairKeys.update(keys, ["a", nil, "c", nil])

      assert after_leave == Map.take(keys, [{"a", "c"}])
    end

    test "a pair that forms again gets another key" do
      keys = PairKeys.update(%{}, ["a", "b", nil, nil])

      alone = PairKeys.update(keys, ["a", nil, nil, nil])
      again = PairKeys.update(alone, ["a", "b", nil, nil])

      assert alone == %{}
      assert again[{"a", "b"}] != keys[{"a", "b"}]
    end
  end

  describe "the process" do
    setup do
      n = System.unique_integer([:positive])
      slots = :"pair_keys_slots_#{n}"
      keys = :"pair_keys_#{n}"
      start_supervised!({Slots, name: slots})
      start_supervised!({PairKeys, name: keys, slots: slots})
      %{slots: slots, keys: keys}
    end

    test "each member gets the keys of its pairs by the other's slot", %{slots: s, keys: k} do
      for user <- ~w(a b c), do: {:ok, _} = Slots.join("z", user, s)
      assert PairKeys.refresh("z", k) == :ok

      a = PairKeys.keys_for("z", "a", k)
      b = PairKeys.keys_for("z", "b", k)
      c = PairKeys.keys_for("z", "c", k)

      assert [Map.keys(a), Map.keys(b), Map.keys(c)] == [[1, 2], [0, 2], [0, 1]]
      assert a[1] == b[0] and a[2] == c[0] and b[2] == c[1]
      assert byte_size(a[1]) == 32
      assert length(Enum.uniq([a[1], a[2], b[2]])) == 3
    end

    test "control: a user who is not seated, or an unknown zone, gets no key", %{
      slots: s,
      keys: k
    } do
      for user <- ~w(a b), do: {:ok, _} = Slots.join("z", user, s)
      :ok = PairKeys.refresh("z", k)

      assert PairKeys.keys_for("z", "stranger", k) == %{}
      assert PairKeys.keys_for("other", "a", k) == %{}
    end

    test "control: a change of the table makes no key until refresh", %{slots: s, keys: k} do
      for user <- ~w(a b), do: {:ok, _} = Slots.join("z", user, s)
      assert PairKeys.keys_for("z", "a", k) == %{}
    end

    test "when the last member leaves, the zone is dropped", %{slots: s, keys: k} do
      for user <- ~w(a b), do: {:ok, _} = Slots.join("z", user, s)
      :ok = PairKeys.refresh("z", k)
      for user <- ~w(a b), do: :ok = Slots.leave("z", user, s)
      :ok = PairKeys.refresh("z", k)

      assert :sys.get_state(k).zones == %{}
    end

    test "the status of the process, which a crash report prints, has no key", %{
      slots: s,
      keys: k
    } do
      for user <- ~w(a b), do: {:ok, _} = Slots.join("z", user, s)
      :ok = PairKeys.refresh("z", k)
      %{1 => key} = PairKeys.keys_for("z", "a", k)

      status = :erlang.term_to_binary(:sys.get_status(k))
      assert :binary.match(status, key) == :nomatch
      assert :binary.match(:erlang.term_to_binary(:sys.get_state(k)), key) != :nomatch
    end

    test "after any joins and leaves every pair has one key that only it holds", ctx do
      %{slots: s, keys: k} = ctx
      seed = :rand.uniform(4_294_967_296)
      state = :rand.seed_s(:exsss, seed)

      {_state, {kept, formed_again}} =
        Enum.reduce(1..@runs, {state, {0, 0}}, fn run, {state, counts} ->
          zone = "zone-#{run}"
          {steps, state} = gen_steps(state)

          {_seen, counts} =
            Enum.reduce(steps, {{%{}, %{}}, counts}, fn step, {{now, ever}, {kept, again}} ->
              apply_step(step, zone, s)
              :ok = PairKeys.refresh(zone, k)
              table = Slots.table(zone, s)
              context = "seed #{seed}, run #{run}, step #{inspect(step)}, table #{inspect(table)}"

              pairs = assert_keys(zone, table, k, context)

              for {pair, key} <- pairs do
                case now do
                  %{^pair => old} ->
                    assert key == old, "#{inspect(pair)} stayed and its key changed (#{context})"

                  _ ->
                    refute key in List.flatten(Map.values(ever)),
                           "#{inspect(pair)} formed with a key used before (#{context})"
                end
              end

              stayed = Enum.count(pairs, fn {pair, _} -> is_map_key(now, pair) end)

              returned =
                Enum.count(pairs, fn {pair, _} ->
                  is_map_key(ever, pair) and not is_map_key(now, pair)
                end)

              ever =
                Enum.reduce(pairs, ever, fn {p, key}, e ->
                  Map.update(e, p, [key], &[key | &1])
                end)

              {{pairs, ever}, {kept + stayed, again + returned}}
            end)

          {state, counts}
        end)

      assert kept > 0, "no pair stayed seated over a step (seed #{seed})"
      assert formed_again > 0, "no pair formed again after a leave (seed #{seed})"
    end
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

  defp assert_keys(zone, table, k, context) do
    seated = for {user, slot} <- Enum.with_index(table), user != nil, do: {user, slot}
    held = Map.new(seated, fn {user, _slot} -> {user, PairKeys.keys_for(zone, user, k)} end)

    for user <- @pool, not is_map_key(held, user) do
      assert PairKeys.keys_for(zone, user, k) == %{},
             "#{user} is not seated and has keys (#{context})"
    end

    for {user, slot} <- seated do
      others = for {_other, other_slot} <- seated, other_slot != slot, do: other_slot

      assert Map.keys(held[user]) == others,
             "#{user} has keys for #{inspect(Map.keys(held[user]))}, not #{inspect(others)} (#{context})"
    end

    pairs =
      for {a, slot_a} <- seated, {b, slot_b} <- seated, a < b, into: %{} do
        key = held[a][slot_b]
        assert byte_size(key) == 32, "the key of #{a} and #{b} is not 32 bytes (#{context})"
        assert held[b][slot_a] == key, "#{a} and #{b} do not hold the same key (#{context})"
        {{a, b}, key}
      end

    keys = Map.values(pairs)
    assert keys == Enum.uniq(keys), "two pairs share a key (#{context})"

    for {{a, b}, key} <- pairs, {user, _slot} <- seated, user not in [a, b] do
      refute key in Map.values(held[user]), "#{user} holds the key of #{a} and #{b} (#{context})"
    end

    pairs
  end
end

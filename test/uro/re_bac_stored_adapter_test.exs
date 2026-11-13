# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.ReBAC.StoredAdapterTest do
  @moduledoc """
  `Uro.ReBAC.StoredAdapter` must answer `check_rel/4` as `Uro.ReBAC.ElixirAdapter` does
  when both hold the same edges.

  The property builds one random edge set in both adapters and asks both for every
  (subject, relation, object) in the pools. The nodes are both subjects and objects, so
  membership chains, cycles and delegations form. The relations are the three the list
  adapter treats specially (`IS_MEMBER_OF`, `CONTROLS`, `DELEGATED_TO`) and two it only
  matches directly. The test fails if no answer was true or none was reached only through
  a membership or a delegation, because a property over empty answers proves little.

  The pools are too small to reach the fuel bound, so the chain tests do that: a chain of
  memberships is followed for seven hops and no further, in both adapters.

  PropCheck is not a dependency of this project, so the edge sets come from `:rand` with a
  seed that is printed when an answer differs. There is no shrinking.
  """
  use Uro.RepoCase, async: false

  alias Uro.ReBAC.ElixirAdapter
  alias Uro.ReBAC.StoredAdapter
  alias Uro.Tuples
  alias Uro.Tuples.Tuple

  @runs 300
  @max_edges 12
  @nodes ~w(n1 n2 n3 n4 n5)
  @relations ~w(IS_MEMBER_OF CONTROLS DELEGATED_TO OWNS CAN_ENTER)

  defp build(adapter, edges) do
    Enum.reduce(edges, adapter.new_graph(), fn {subj, obj, rel}, graph ->
      adapter.add_edge(graph, subj, obj, rel)
    end)
  end

  defp chain(length) do
    for n <- 1..length, do: {"g#{n - 1}", "g#{n}", "IS_MEMBER_OF"}
  end

  test "a direct edge is found, and add_edge writes the tuple" do
    graph = build(StoredAdapter, [{"alice", "zone1", "OWNS"}])

    assert Tuples.has?("alice", "OWNS", "zone1")
    assert StoredAdapter.check_rel(graph, "alice", "OWNS", "zone1")
    refute StoredAdapter.check_rel(graph, "bob", "OWNS", "zone1")
    refute StoredAdapter.check_rel(graph, "alice", "CAN_ENTER", "zone1")
  end

  test "a member has the relations of its group, through two groups" do
    graph =
      build(StoredAdapter, [
        {"alice", "group_a", "IS_MEMBER_OF"},
        {"group_a", "group_b", "IS_MEMBER_OF"},
        {"group_b", "zone1", "CAN_ENTER"}
      ])

    assert StoredAdapter.check_rel(graph, "alice", "CAN_ENTER", "zone1")
    refute StoredAdapter.check_rel(graph, "bob", "CAN_ENTER", "zone1")
    refute StoredAdapter.check_rel(graph, "alice", "OWNS", "zone1")
  end

  test "CONTROLS holds through DELEGATED_TO, also for a member of the delegate" do
    graph =
      build(StoredAdapter, [
        {"zone1", "wardens", "DELEGATED_TO"},
        {"alice", "wardens", "IS_MEMBER_OF"}
      ])

    assert StoredAdapter.check_rel(graph, "wardens", "CONTROLS", "zone1")
    assert StoredAdapter.check_rel(graph, "alice", "CONTROLS", "zone1")
    refute StoredAdapter.check_rel(graph, "bob", "CONTROLS", "zone1")
    refute StoredAdapter.check_rel(graph, "alice", "OWNS", "zone1")
  end

  test "an answer follows the table: a deleted tuple no longer grants" do
    graph = build(StoredAdapter, [{"alice", "zone1", "CAN_ENTER"}])
    assert StoredAdapter.check_rel(graph, "alice", "CAN_ENTER", "zone1")

    {:ok, 1} = Tuples.delete("alice", "CAN_ENTER", "zone1")
    refute StoredAdapter.check_rel(graph, "alice", "CAN_ENTER", "zone1")
  end

  test "control: add_edge raises on an empty subject and stores nothing" do
    assert_raise ArgumentError, fn ->
      StoredAdapter.add_edge(StoredAdapter.new_graph(), "", "zone1", "OWNS")
    end

    assert Repo.aggregate(Tuple, :count) == 0
  end

  test "a membership chain is followed for seven hops and no further, as in the list adapter" do
    for length <- 1..10 do
      Repo.delete_all(Tuple)
      last = "g#{length}"
      edges = [{last, "zone1", "OWNS"}, {"zone1", last, "DELEGATED_TO"} | chain(length)]
      stored = build(StoredAdapter, edges)
      list = build(ElixirAdapter, edges)

      for {rel, obj} <- [{"OWNS", "zone1"}, {"CONTROLS", "zone1"}, {"IS_MEMBER_OF", last}] do
        expected = ElixirAdapter.check_rel(list, "g0", rel, obj)

        assert StoredAdapter.check_rel(stored, "g0", rel, obj) == expected,
               "chain of #{length}: g0 #{rel} #{obj} should be #{expected}"
      end

      assert StoredAdapter.check_rel(stored, "g0", "OWNS", "zone1") == length <= 7
      assert StoredAdapter.check_rel(stored, "g0", "IS_MEMBER_OF", last) == length <= 8
    end
  end

  test "a membership cycle ends" do
    graph = build(StoredAdapter, [{"a", "b", "IS_MEMBER_OF"}, {"b", "a", "IS_MEMBER_OF"}])

    refute StoredAdapter.check_rel(graph, "a", "OWNS", "zone1")
    assert StoredAdapter.check_rel(graph, "a", "IS_MEMBER_OF", "a")
  end

  test "for any edge set the stored adapter answers as the list adapter does" do
    seed = :rand.uniform(4_294_967_296)
    state = :rand.seed_s(:exsss, seed)

    {_state, {granted, indirect}} =
      Enum.reduce(1..@runs, {state, {0, 0}}, fn run, {state, counts} ->
        Repo.delete_all(Tuple)
        {edges, state} = gen_edges(state)
        stored = build(StoredAdapter, edges)
        list = build(ElixirAdapter, edges)

        counts =
          for subj <- @nodes, rel <- @relations, obj <- @nodes, reduce: counts do
            {granted, indirect} ->
              expected = ElixirAdapter.check_rel(list, subj, rel, obj)

              assert StoredAdapter.check_rel(stored, subj, rel, obj) == expected,
                     "#{subj} #{rel} #{obj} should be #{expected} " <>
                       "(seed #{seed}, run #{run}, edges #{inspect(edges)})"

              direct = {subj, obj, rel} in edges

              {granted + if(expected, do: 1, else: 0),
               indirect + if(expected and not direct, do: 1, else: 0)}
          end

        {state, counts}
      end)

    assert granted > 0, "no answer was true (seed #{seed})"
    assert indirect > 0, "no answer came through a membership or a delegation (seed #{seed})"
  end

  defp gen_edges(state) do
    {n, state} = :rand.uniform_s(@max_edges + 1, state)

    Enum.map_reduce(List.duplicate(nil, n - 1), state, fn _, state ->
      {subj, state} = pick(@nodes, state)
      {obj, state} = pick(@nodes, state)
      {rel, state} = pick(@relations, state)
      {{subj, obj, rel}, state}
    end)
  end

  defp pick(pool, state) do
    {n, state} = :rand.uniform_s(length(pool), state)
    {Enum.at(pool, n - 1), state}
  end
end

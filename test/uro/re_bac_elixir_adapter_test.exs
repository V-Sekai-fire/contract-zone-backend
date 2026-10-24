# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.ReBAC.ElixirAdapterTest do
  @moduledoc """
  Regression suite for `Uro.ReBAC.ElixirAdapter` (plain Elixir,
  RFD66606-0040). These cases originally ran through both
  `Uro.ReBAC.TaskweftAdapter` (the native `tw_rebac.hpp` NIF) and then
  `Uro.ReBAC.SandboxAdapter` (compiled Scheme in the libriscv guest,
  RFD66606-0022), asserting agreement, before both were retired (RFD66606-0038,
  RFD66606-0039) in favor of this direct port. Each case just pins the value
  that comparison already proved correct.
  """
  use ExUnit.Case, async: true

  alias Uro.ReBAC.ElixirAdapter

  defp build(edges) do
    Enum.reduce(edges, ElixirAdapter.new_graph(), fn {subj, obj, rel}, graph ->
      ElixirAdapter.add_edge(graph, subj, obj, rel)
    end)
  end

  defp check(edges, subj, rel, obj), do: build(edges) |> ElixirAdapter.check_rel(subj, rel, obj)

  test "direct edge match" do
    edges = [{"alice", "zone1", "OWNS"}]
    assert check(edges, "alice", "OWNS", "zone1")
    refute check(edges, "bob", "OWNS", "zone1")
    refute check(edges, "alice", "CAN_ENTER", "zone1")
  end

  test "transitive IS_MEMBER_OF inheritance" do
    edges = [
      {"alice", "avatar_uploaders", "IS_MEMBER_OF"},
      {"avatar_uploaders", "uploads", "HAS_CAPABILITY"}
    ]

    assert check(edges, "alice", "HAS_CAPABILITY", "uploads")
    refute check(edges, "bob", "HAS_CAPABILITY", "uploads")
  end

  test "two-deep membership chain" do
    edges = [
      {"alice", "group_a", "IS_MEMBER_OF"},
      {"group_a", "group_b", "IS_MEMBER_OF"},
      {"group_b", "zone1", "CAN_ENTER"}
    ]

    assert check(edges, "alice", "CAN_ENTER", "zone1")
  end

  test "CONTROLS via DELEGATED_TO inversion" do
    edges = [{"zone1", "alice", "DELEGATED_TO"}]
    assert check(edges, "alice", "CONTROLS", "zone1")
    refute check([], "alice", "CONTROLS", "zone1")
  end

  test "empty graph is always false" do
    refute check([], "alice", "OWNS", "zone1")
  end

  test "membership does not imply an unrelated relation" do
    edges = [{"alice", "group_a", "IS_MEMBER_OF"}]
    refute check(edges, "alice", "OWNS", "zone1")
  end

  test "matches the real-world zone-entry graph shape from Uro.VSekai" do
    edges = [
      {"owner-1", "zone-1", "OWNS"},
      {"owner-1", "zone-1", "CAN_ENTER"}
    ]

    assert check(edges, "owner-1", "CAN_ENTER", "zone-1")
    refute check(edges, "stranger-2", "CAN_ENTER", "zone-1")
  end
end

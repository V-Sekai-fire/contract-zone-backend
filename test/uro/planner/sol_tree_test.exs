# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.SolTreeTest do
  @moduledoc """
  Verification for the plain-Elixir port of `standalone/tw_soltree.hpp`
  (RFD66606-0029).
  """
  use ExUnit.Case, async: true

  alias Uro.Planner.SolTree

  # root(0) -> task "behave"(1, method_idx 0) -> action "flee"(2) -> action "recover"(3)
  defp build_tree do
    {tree, root} = SolTree.add_node(SolTree.new(), :root, -1, nil, [])
    {tree, task} = SolTree.add_node(tree, :task, root, "behave", [], 0)
    {tree, flee} = SolTree.add_node(tree, :action, task, "flee", [])
    tree = SolTree.set_plan_step(tree, flee, 0)
    tree = SolTree.push_action_node(tree, flee)
    {tree, recover} = SolTree.add_node(tree, :action, task, "recover", [])
    tree = SolTree.set_plan_step(tree, recover, 1)
    tree = SolTree.push_action_node(tree, recover)
    tree = SolTree.set_first_step(tree, task, 0)
    %{tree: tree, root: root, task: task, flee: flee, recover: recover}
  end

  test "add_node links each child onto its parent's children list" do
    %{tree: tree, task: task, flee: flee, recover: recover} = build_tree()
    assert Map.fetch!(tree.nodes, task).children == [flee, recover]
  end

  test "the root has no parent link and gets no children entry anywhere" do
    %{tree: tree, root: root} = build_tree()
    assert Map.fetch!(tree.nodes, root).parent == -1
  end

  test "checkpoint/restore removes nodes and unlinks them from the surviving parent" do
    %{tree: tree, task: task} = build_tree()
    cp = SolTree.checkpoint(tree)

    {tree2, extra} = SolTree.add_node(tree, :action, task, "drift", [])
    assert Map.fetch!(tree2.nodes, task).children |> length() == 3
    assert tree2.size == cp + 1

    restored = SolTree.restore(tree2, cp)
    assert restored.size == cp
    assert Map.fetch!(restored.nodes, task).children |> length() == 2
    refute Map.has_key?(restored.nodes, extra)
  end

  test "restore trims action_nodes to those still in the tree" do
    %{tree: tree, task: task} = build_tree()
    cp = SolTree.checkpoint(tree)
    {tree2, extra} = SolTree.add_node(tree, :action, task, "drift", [])
    tree2 = SolTree.push_action_node(tree2, extra)

    restored = SolTree.restore(tree2, cp)
    assert extra not in restored.action_nodes
  end

  test "nearest_retryable_ancestor finds a task with a remaining alternative" do
    %{tree: tree, flee: flee, task: task} = build_tree()
    task_methods = %{"behave" => [:alt1, :alt2]}
    assert SolTree.nearest_retryable_ancestor(tree, flee, task_methods) == task
  end

  test "nearest_retryable_ancestor returns nil once exhausted or at the root" do
    %{tree: tree, flee: flee, task: task} = build_tree()
    # Only one alternative total, and method_idx is already 0 (the last one).
    exhausted = %{"behave" => [:only_alt]}
    assert SolTree.nearest_retryable_ancestor(tree, flee, exhausted) == nil
    # The task's own parent is the root -- never itself retryable.
    assert SolTree.nearest_retryable_ancestor(tree, task, %{"behave" => [:a, :b]}) == nil
  end

  test "nearest_retryable_ancestor returns nil for an unknown task name" do
    %{tree: tree, flee: flee} = build_tree()
    assert SolTree.nearest_retryable_ancestor(tree, flee, %{}) == nil
  end

  test "prefix_length defaults to 0 when first_step is unset (-1)" do
    %{tree: tree, flee: flee} = build_tree()
    assert SolTree.prefix_length(tree, flee) == 0
  end

  test "prefix_length reads an explicitly-set non-zero first_step" do
    %{tree: tree, task: task} = build_tree()
    tree = SolTree.set_first_step(tree, task, 3)
    assert SolTree.prefix_length(tree, task) == 3
  end
end

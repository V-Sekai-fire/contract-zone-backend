# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.ExplainTest do
  @moduledoc """
  Verification for the plain-Elixir port of `standalone/tw_explain.hpp`
  (RFD66606-0037).
  """
  use ExUnit.Case, async: true

  alias Uro.Planner.{Explain, SolTree}

  describe "node_kind_name/1" do
    test "maps every SolTree kind atom to its native explain-tree name" do
      assert Explain.node_kind_name(:root) == "root"
      assert Explain.node_kind_name(:task) == "task"
      assert Explain.node_kind_name(:action) == "action"
      assert Explain.node_kind_name(:goal) == "goal"
      assert Explain.node_kind_name(:multi_goal) == "multigoal"
    end
  end

  describe "call_to_list/1" do
    test "prepends the action name to its args" do
      assert Explain.call_to_list({"move", ["robot1", "kitchen"]}) == [
               "move",
               "robot1",
               "kitchen"
             ]
    end
  end

  describe "solution_tree_map/2" do
    # root(0) -> task "behave"(1) -> action "move"(2, plan_step 0)
    defp build_tree do
      {tree, root} = SolTree.add_node(SolTree.new(), :root, -1, nil, [])
      {tree, task} = SolTree.add_node(tree, :task, root, "behave", [], 0)
      {tree, a0} = SolTree.add_node(tree, :action, task, "move", ["robot1", "kitchen"])
      tree = tree |> SolTree.set_plan_step(a0, 0) |> SolTree.push_action_node(a0)
      SolTree.set_first_step(tree, task, 0)
    end

    test "builds the full explanation map for a solved plan" do
      tree = build_tree()
      plan = [{"move", ["robot1", "kitchen"]}]
      result = Explain.solution_tree_map(tree, plan)

      assert result.mode == "native"
      assert result.status == "ok"
      assert result.plan_steps == [["move", "robot1", "kitchen"]]
      assert result.action_nodes == [2]
      assert length(result.solution_tree) == 3

      root_map = Enum.at(result.solution_tree, 0)
      assert root_map.kind == "root"
      assert root_map.parent == -1
      refute Map.has_key?(root_map, :name)

      task_map = Enum.at(result.solution_tree, 1)
      assert task_map.kind == "task"
      assert task_map.name == "behave"
      assert task_map.first_step == 0

      action_map = Enum.at(result.solution_tree, 2)
      assert action_map.kind == "action"
      assert action_map.name == "move"
      assert action_map.args == ["robot1", "kitchen"]
      assert action_map.plan_step == 0
    end
  end

  describe "failure_task_map/3 and no_plan_explain_map/2" do
    defp domain do
      %{actions: MapSet.new(["move"]), task_methods: %{"behave" => [:alt1]}}
    end

    test "a resolvable action call" do
      result = Explain.failure_task_map({:call, "move", ["r1"]}, domain(), 0)

      assert result == %{
               index: 0,
               kind: "task_call",
               name: "move",
               args: ["r1"],
               resolvable: true,
               symbol_type: "action"
             }
    end

    test "a resolvable compound task call" do
      result = Explain.failure_task_map({:call, "behave", []}, domain(), 1)
      assert result.symbol_type == "method"
      assert result.resolvable
    end

    test "an unresolvable call" do
      result = Explain.failure_task_map({:call, "nonexistent", []}, domain(), 2)
      assert result.symbol_type == "unknown"
      refute result.resolvable
    end

    test "a goal task" do
      result = Explain.failure_task_map({:goal, [{"loc", "r1", "kitchen"}]}, domain(), 0)

      assert result == %{
               index: 0,
               kind: "goal",
               bindings: [%{var: "loc", key: "r1", desired: "kitchen"}]
             }
    end

    test "a multigoal task" do
      result = Explain.failure_task_map({:multi_goal, [{"loc", "r1", "kitchen"}]}, domain(), 0)
      assert result.kind == "multigoal"
    end

    test "no_plan_explain_map builds the full failure tree" do
      tasks = [{:call, "move", ["r1"]}, {:goal, [{"loc", "r1", "kitchen"}]}]
      result = Explain.no_plan_explain_map(tasks, domain())

      assert result.status == "no_plan"
      assert result.explain.summary == "planner returned no_plan"
      assert length(result.explain.failure_tree) == 2
      assert Enum.at(result.explain.failure_tree, 0).kind == "task_call"
      assert Enum.at(result.explain.failure_tree, 1).kind == "goal"
    end
  end
end

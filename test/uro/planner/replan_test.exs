# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.ReplanTest do
  @moduledoc """
  Verification for the plain-Elixir port of `standalone/tw_replan.hpp`
  (RFD66606-0030). The actual planner (`tw_plan`/`tw_plan_with_tree`) is a
  fake here on purpose -- this module's own job is orchestration
  (simulate/blacklist/prefix-splicing), not search, per its moduledoc.
  """
  use ExUnit.Case, async: true

  alias Uro.Planner.{Replan, SolTree}

  # Module attributes can't hold anonymous functions (not escapable at
  # compile time) -- a plain function stands in for @actions instead.
  defp actions do
    %{
      "inc" => fn state, [n] -> %{state | count: state.count + n} end,
      "fail" => fn _state, _args -> nil end
    }
  end

  describe "simulate/3" do
    test "runs every action to completion when all succeed" do
      plan = [{"inc", [1]}, {"inc", [2]}]
      result = Replan.simulate(%{count: 0}, plan, actions())
      assert result == %{completed_steps: 2, fail_step: -1, fail_action: nil, state: %{count: 3}}
    end

    test "stops at the first action that returns nil" do
      plan = [{"inc", [1]}, {"fail", []}, {"inc", [100]}]
      result = Replan.simulate(%{count: 0}, plan, actions())

      assert result == %{
               completed_steps: 1,
               fail_step: 1,
               fail_action: "fail",
               state: %{count: 1}
             }
    end

    test "stops at an unknown action name" do
      plan = [{"inc", [1]}, {"nonexistent", []}]
      result = Replan.simulate(%{count: 0}, plan, actions())
      assert result.fail_step == 1
      assert result.fail_action == "nonexistent"
      assert result.state == %{count: 1}
    end

    test "an empty plan completes with the initial state" do
      assert Replan.simulate(%{count: 0}, [], actions()) ==
               %{completed_steps: 0, fail_step: -1, fail_action: nil, state: %{count: 0}}
    end
  end

  describe "replan/5" do
    test "auto-detects the failure, blacklists the exact failed command, and calls plan_fn" do
      plan = [{"inc", [1]}, {"fail", []}]
      tasks = [:whatever]
      domain = %{}

      result =
        Replan.replan(%{count: 0}, plan, tasks, domain,
          actions: actions(),
          plan_fn: fn state, ^tasks, ^domain, blacklist ->
            assert state == %{count: 1}
            assert MapSet.member?(blacklist, "fail")
            [{"alternative", []}]
          end
        )

      assert result.recovered
      assert result.new_plan == [{"alternative", []}]
      assert MapSet.member?(result.blacklist, "fail")
    end

    test "an explicit fail_step is honored over auto-detection" do
      plan = [{"inc", [1]}, {"inc", [2]}, {"inc", [3]}]

      result =
        Replan.replan(%{count: 0}, plan, [], %{},
          fail_step: 1,
          actions: actions(),
          plan_fn: fn state, _tasks, _domain, blacklist ->
            assert state == %{count: 1}
            assert MapSet.member?(blacklist, "inc\x1f2")
            []
          end
        )

      assert result.simulate.fail_step == 1
      assert result.simulate.fail_action == "inc"
      assert result.recovered
    end

    test "recovered is false when plan_fn finds nothing" do
      plan = [{"fail", []}]

      result =
        Replan.replan(%{count: 0}, plan, [], %{},
          actions: actions(),
          plan_fn: fn _s, _t, _d, _bl -> nil end
        )

      refute result.recovered
      assert result.new_plan == nil
    end
  end

  describe "replan_incremental/6" do
    # root(0) -> task "behave"(1, method_idx 0, 2 alternatives) ->
    #   action "inc"(2, plan_step 0) -> action "fail"(3, plan_step 1)
    defp build_sol_tree do
      {tree, root} = SolTree.add_node(SolTree.new(), :root, -1, nil, [])
      {tree, task} = SolTree.add_node(tree, :task, root, "behave", [], 0)
      {tree, a0} = SolTree.add_node(tree, :action, task, "inc", [1])
      tree = tree |> SolTree.set_plan_step(a0, 0) |> SolTree.push_action_node(a0)
      {tree, a1} = SolTree.add_node(tree, :action, task, "fail", [])
      tree = tree |> SolTree.set_plan_step(a1, 1) |> SolTree.push_action_node(a1)
      tree = SolTree.set_first_step(tree, task, 0)
      tree
    end

    test "no failure: returns the original plan unchanged, no planner call needed" do
      plan = [{"inc", [1]}, {"inc", [2]}]
      sol_tree = build_sol_tree()
      domain = %{task_methods: %{"behave" => [:alt1, :alt2]}}

      result =
        Replan.replan_incremental(%{count: 0}, plan, [], domain, sol_tree,
          actions: actions(),
          plan_fn: fn _s, _t, _d, _bl -> flunk("plan_fn should not be called") end,
          plan_with_tree_fn: fn _s, _t, _d, _bl, _skip ->
            flunk("plan_with_tree_fn should not be called")
          end
        )

      assert result.recovered
      assert result.new_plan == plan
    end

    test "a retryable ancestor skips its exhausted method and replans from the prefix" do
      plan = [{"inc", [1]}, {"fail", []}]
      sol_tree = build_sol_tree()
      domain = %{task_methods: %{"behave" => [:alt1, :alt2]}}

      result =
        Replan.replan_incremental(%{count: 0}, plan, [:whatever], domain, sol_tree,
          actions: actions(),
          plan_fn: fn _s, _t, _d, _bl -> flunk("plan_fn (full replan) should not be called") end,
          plan_with_tree_fn: fn state, [:whatever], ^domain, blacklist, skip ->
            # prefix_length(task) == 0 (first_step set to 0), so replan
            # starts from the ORIGINAL init_state, not the post-"inc" state.
            assert state == %{count: 0}
            assert MapSet.member?(blacklist, "fail")
            assert skip == %{"behave" => MapSet.new([0])}
            [{"recovered_step", []}]
          end
        )

      assert result.recovered
      assert result.new_plan == [{"recovered_step", []}]
    end

    test "no retryable ancestor falls back to a full replan via plan_fn" do
      plan = [{"inc", [1]}, {"fail", []}]
      sol_tree = build_sol_tree()
      # Only one alternative total, and method_idx is already 0 (exhausted).
      domain = %{task_methods: %{"behave" => [:only_alt]}}

      result =
        Replan.replan_incremental(%{count: 0}, plan, [:whatever], domain, sol_tree,
          actions: actions(),
          plan_fn: fn state, [:whatever], ^domain, blacklist ->
            assert state == %{count: 1}
            assert MapSet.member?(blacklist, "fail")
            [{"fallback_step", []}]
          end,
          plan_with_tree_fn: fn _s, _t, _d, _bl, _skip ->
            flunk("plan_with_tree_fn should not be called")
          end
        )

      assert result.recovered
      assert result.new_plan == [{"fallback_step", []}]
    end
  end
end

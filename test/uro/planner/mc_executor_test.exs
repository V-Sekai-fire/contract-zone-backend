# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.MCExecutorTest do
  @moduledoc """
  Verification for the plain-Elixir port of `standalone/tw_mc_executor.hpp`
  (RFD66606-0034). The RNG is Erlang's `:rand`, not the original's
  `std::mt19937_64` -- these tests pin probability-1.0 (always succeeds,
  since `:rand.uniform_s/1` draws are always < 1.0) and probability-0.0
  (never succeeds, since no draw is < 0.0) edges rather than exact draw
  sequences, so they hold regardless of which RNG backs `:rand`.
  """
  use ExUnit.Case, async: true

  alias Uro.Planner.MCExecutor

  defp actions do
    %{
      "inc" => fn state, [n] -> %{state | count: state.count + n} end,
      "fail" => fn _state, _args -> nil end
    }
  end

  test "every step succeeds when every probability is 1.0" do
    plan = [{"inc", [1]}, {"inc", [2]}]

    result =
      MCExecutor.execute(%{count: 0}, plan, probs: [1.0, 1.0], actions: actions())

    assert result.completed == 2
    assert result.failed_at == nil
    assert Enum.all?(result.steps, & &1.succeeded)
    assert List.last(result.steps).state == %{count: 3}
  end

  test "an empty probs list defaults every step to probability 1.0" do
    plan = [{"inc", [5]}]
    result = MCExecutor.execute(%{count: 0}, plan, actions: actions())

    assert result.completed == 1
    assert result.failed_at == nil
    assert hd(result.steps).state == %{count: 5}
  end

  test "probability 0.0 always fails the step immediately" do
    plan = [{"inc", [1]}, {"inc", [2]}]
    result = MCExecutor.execute(%{count: 0}, plan, probs: [0.0], actions: actions())

    assert result.completed == 0
    assert result.failed_at == 0
    assert length(result.steps) == 1
    refute hd(result.steps).succeeded
    assert hd(result.steps).state == nil
  end

  test "an action returning nil is recorded as a failure and halts the plan" do
    plan = [{"inc", [1]}, {"fail", []}, {"inc", [100]}]
    result = MCExecutor.execute(%{count: 0}, plan, probs: [1.0, 1.0, 1.0], actions: actions())

    assert result.completed == 1
    assert result.failed_at == 1
    assert length(result.steps) == 2
    assert Enum.at(result.steps, 0).succeeded
    refute Enum.at(result.steps, 1).succeeded
  end

  test "an unknown action name with a drawn success stays succeeded, state unchanged" do
    plan = [{"nonexistent", []}, {"inc", [1]}]
    result = MCExecutor.execute(%{count: 0}, plan, probs: [1.0, 1.0], actions: actions())

    assert result.completed == 2
    assert result.failed_at == nil
    assert hd(result.steps).succeeded
    assert hd(result.steps).state == %{count: 0}
    assert List.last(result.steps).state == %{count: 1}
  end

  test "the same seed produces the same probabilistic outcome sequence" do
    plan = [{"inc", [1]}, {"inc", [1]}, {"inc", [1]}]
    probs = [0.5, 0.5, 0.5]

    result_a = MCExecutor.execute(%{count: 0}, plan, probs: probs, seed: 42, actions: actions())
    result_b = MCExecutor.execute(%{count: 0}, plan, probs: probs, seed: 42, actions: actions())

    assert result_a == result_b
  end
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.LoopCoreTest do
  @moduledoc """
  Golden-vector fidelity (RFD66606-0026) plus real-parameterization proof
  (RFD66606-0027) for the plain-Elixir loot/combat/progression ports.
  """
  use ExUnit.Case, async: true

  alias Uro.LoopCore.{CombatCore, Instance, LootCore, ProgressionCore}

  describe "golden vectors (already established by s7_riscv_*_golden_test.cpp)" do
    test "loot-roll(42, [(1,10),(2,20),(3,5)]) == 3" do
      assert LootCore.roll(42, [{1, 10}, {2, 20}, {3, 5}]) == 3
    end

    test "combat-replay: spawn, 30 ticks, one opener attack -> tick=30, hp=90, alive" do
      events = [:spawn] ++ List.duplicate(:tick, 30) ++ [:attack]
      {state, _log} = CombatCore.replay(events)
      assert state.tick == 30
      assert state.hp == 90
      assert state.alive
    end

    test "progression-replay: grant, grant, sell(50), train, buyArt(1) -> credits=150, affinity=16" do
      events = [{:grant, 1}, {:grant, 1}, {:sell, 1, 50}, :train, {:buy_art, 1}]
      {profile, _log} = ProgressionCore.replay(events)
      assert profile.credits == 150
      assert profile.affinity == 16
      assert profile.arts == [1]
    end
  end

  describe "real parameterization (not just fixed replay) via Uro.LoopCore.Instance" do
    setup do
      {:ok, pid} = start_supervised(Instance)
      %{pid: pid}
    end

    test "loot_roll with a different table than the golden vector", %{pid: pid} do
      # A single-item table always resolves to that item, regardless of seed.
      assert Instance.loot_roll(pid, 7, [{99, 1}]) == 99
      assert Instance.loot_roll(pid, 1234, [{99, 1}]) == 99
    end

    test "combat_step resolves a real hit and persists state across calls", %{pid: pid} do
      {%CombatCore.State{alive: true, hp: 100}, []} = Instance.combat_step(pid, :spawn)
      # An attack lands only once the invulnerability window (30 ticks
      # after spawn) has passed -- matching resolve-swing's own guard.
      for _ <- 1..30, do: Instance.combat_step(pid, :tick)
      {%CombatCore.State{hp: 90}, [{:swing, 0}, {:hit, 10}]} = Instance.combat_step(pid, :attack)

      # State persisted in the actor: a second read confirms it, not a
      # fresh replay from scratch.
      assert %{combat: %CombatCore.State{hp: 90}} = Instance.state(pid)
    end

    test "progression_step commits a grant and persists it", %{pid: pid} do
      {%ProgressionCore.Profile{items: [{42, 1}]}, [{:granted, 42}]} =
        Instance.progression_step(pid, {:grant, 42})

      assert %{profile: %ProgressionCore.Profile{items: [{42, 1}]}} = Instance.state(pid)
    end

    test "buyArt is refused when affinity is too low", %{pid: pid} do
      {profile, [{:refused_gate, 3}]} = Instance.progression_step(pid, {:buy_art, 3})
      assert profile == ProgressionCore.initial_profile()
    end
  end
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.LoopCore.Instance do
  @moduledoc """
  One actor per active Field instance (RFD66606-0027), holding that
  instance's live combat state and progression profile and exposing
  real per-call operations against `Uro.LoopCore.{CombatCore,LootCore,
  ProgressionCore}` -- not the fixed golden-vector replays
  `c_src/guest/weft_guest.c`'s `guest_combat_replay`/
  `guest_progression_replay`/`guest_loot_roll` wrappers are limited to.

  Revised from the original RISC-V-sandboxed design (RFD66606-0020/0026's
  first draft): this content is fully-trusted, team-authored game
  logic translated line-for-line from Lean-verified sources, not
  untrusted script content -- the trust boundary the libriscv sandbox
  exists for doesn't apply here, so "pause"/"resume"/"gas"/"sandbox"
  reduce to what a GenServer already gives for free: idle between
  calls, the next call as resume, an ordinary `GenServer.call/3` timeout
  as the gas budget, and BEAM's own per-process isolation as the
  sandbox. `WeftWarpBurrito.Program`'s trampoline-based pause/resume/
  gas remains the right tool for genuinely untrusted content (ReBAC
  graphs, planner domains, RFD66606-0021/0022/0023) -- this module is not
  that, and doesn't pretend to be.
  """
  use GenServer

  alias Uro.LoopCore.{CombatCore, LootCore, ProgressionCore}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, :ok, opts)

  @doc "combat_step(pid, event) -- event :: :tick | :spawn | :attack."
  def combat_step(pid, event), do: GenServer.call(pid, {:combat_step, event})

  @doc "loot_roll(pid, seed, table) -- table is a list of {item, weight} tuples."
  def loot_roll(pid, seed, table), do: GenServer.call(pid, {:loot_roll, seed, table})

  @doc "progression_step(pid, event)."
  def progression_step(pid, event), do: GenServer.call(pid, {:progression_step, event})

  @doc "The instance's current {combat_state, profile}."
  def state(pid), do: GenServer.call(pid, :state)

  @impl true
  def init(:ok) do
    {:ok, %{combat: CombatCore.initial_state(), profile: ProgressionCore.initial_profile()}}
  end

  @impl true
  def handle_call({:combat_step, event}, _from, s) do
    {new_combat, log} = CombatCore.step(s.combat, event)
    {:reply, {new_combat, log}, %{s | combat: new_combat}}
  end

  def handle_call({:loot_roll, seed, table}, _from, s) do
    {:reply, LootCore.roll(seed, table), s}
  end

  def handle_call({:progression_step, event}, _from, s) do
    {new_profile, log} = ProgressionCore.step(s.profile, event)
    {:reply, {new_profile, log}, %{s | profile: new_profile}}
  end

  def handle_call(:state, _from, s), do: {:reply, s, s}
end

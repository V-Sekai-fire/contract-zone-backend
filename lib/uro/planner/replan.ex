# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.Replan do
  @moduledoc """
  Hand-ported from `standalone/tw_replan.hpp` into plain Elixir --
  same reasoning as `Uro.LoopCore`/`Uro.Planner.{Temporal,SolTree}`'s
  ports (RFD66606-0026/0028/0029): self-contained orchestration logic, no
  untrusted content.

  Unlike those, this module does NOT re-derive the actual HTN search
  (`tw_plan`/`tw_plan_with_tree`) a third time -- `Uro.Planner.
  ElixirAdapter` (RFD66606-0039) has its own, plan/1-shaped entry point, and
  `tw_plan_with_tree` (the tree-returning sibling `Replan`/`SolTree`
  actually need) has no plain-Elixir port of its own yet. The planner
  stays an injected dependency (`plan_fn`/`plan_with_tree_fn`),
  matching the original's own `tw_plan`/`tw_plan_with_tree` parameters
  exactly -- this keeps `simulate/3`, `replan/5`, and
  `replan_incremental/6` fully testable against a fake planner, and
  makes them a real, reusable seam once that tree-returning variant
  exists to plug in.

  A plan step is `{name, args}` (mirroring `TwCall`); `actions` is a
  `%{name => (state, args -> state | nil)}` map (mirroring
  `TwDomain.actions`) -- `nil` return means the action failed to apply,
  exactly like the original's `TwActionFn` contract.
  """

  alias Uro.Planner.SolTree

  @type call :: {String.t(), [term()]}
  @type action_fn :: (map(), [term()] -> map() | nil)
  @type actions :: %{String.t() => action_fn()}

  @type simulate_result :: %{
          completed_steps: non_neg_integer(),
          fail_step: integer(),
          fail_action: String.t() | nil,
          state: map()
        }

  @doc """
  Applies `plan` actions one by one against `init_state`, stopping at
  the first failure (an unknown action name, or an action returning
  `nil`). `fail_step: -1` means every action succeeded.
  """
  @spec simulate(map(), [call()], actions()) :: simulate_result()
  def simulate(init_state, plan, actions) do
    plan
    |> Enum.with_index()
    |> Enum.reduce_while({0, init_state}, fn {{name, args}, i}, {_completed, cur} ->
      case Map.fetch(actions, name) do
        :error ->
          {:halt, {:fail, i, name, cur}}

        {:ok, action_fn} ->
          case action_fn.(cur, args) do
            nil -> {:halt, {:fail, i, name, cur}}
            next -> {:cont, {i + 1, next}}
          end
      end
    end)
    |> case do
      {completed, final_state} ->
        %{completed_steps: completed, fail_step: -1, fail_action: nil, state: final_state}

      {:fail, i, name, state_at_failure} ->
        %{completed_steps: i, fail_step: i, fail_action: name, state: state_at_failure}
    end
  end

  # Mirrors tw_call_key: name + '\x1f' + each arg's string form, joined
  # -- a canonical key for blacklist/skip-map membership tests.
  defp call_key({name, args}) do
    Enum.reduce(args, name, fn arg, acc -> acc <> "\x1f" <> to_string(arg) end)
  end

  defp simulate_to_fail_step(init_state, original_plan, actions, fail_step) do
    if fail_step < 0 or fail_step >= length(original_plan) do
      simulate(init_state, original_plan, actions)
    else
      prefix = Enum.take(original_plan, fail_step)
      partial = simulate(init_state, prefix, actions)
      {name, _args} = Enum.at(original_plan, fail_step)

      %{completed_steps: fail_step, fail_step: fail_step, fail_action: name, state: partial.state}
    end
  end

  @doc """
  Simulates `original_plan` up to `fail_step` (or until first failure
  if `fail_step` is negative/out of range), blacklists the specific
  `{name, args}` command that failed (not just the action definition --
  the planner must find an alternative path, not just retry the same
  step), then replans from the failure state using `original_tasks`.

  `opts`: `:fail_step` (default `-1`), `:actions` (required), `:plan_fn`
  (required) -- `(state, tasks, domain, blacklist) -> plan | nil`,
  matching `tw_plan`'s own signature.
  """
  @spec replan(map(), [call()], [term()], term(), keyword()) :: %{
          simulate: simulate_result(),
          new_plan: [call()] | nil,
          recovered: boolean(),
          blacklist: MapSet.t(String.t())
        }
  def replan(init_state, original_plan, original_tasks, domain, opts) do
    fail_step = Keyword.get(opts, :fail_step, -1)
    actions = Keyword.fetch!(opts, :actions)
    plan_fn = Keyword.fetch!(opts, :plan_fn)

    sim = simulate_to_fail_step(init_state, original_plan, actions, fail_step)
    replan_state = sim.state || init_state

    blacklist =
      if sim.fail_step >= 0 and sim.fail_step < length(original_plan) do
        MapSet.new([call_key(Enum.at(original_plan, sim.fail_step))])
      else
        MapSet.new()
      end

    new_plan = plan_fn.(replan_state, original_tasks, domain, blacklist)
    %{simulate: sim, new_plan: new_plan, recovered: new_plan != nil, blacklist: blacklist}
  end

  @doc """
  Incremental replan using a `Uro.Planner.SolTree` from a previous
  tree-building plan call: locates the nearest Task/Goal ancestor of
  the failed action that still has an untried method alternative,
  simulates only the plan prefix before that ancestor's subtree, and
  replans from there -- skipping the method choice that produced the
  failed plan, instead of restarting the full search. Falls back to a
  full replan (via `plan_fn`) when no such ancestor exists.

  `opts`: `:fail_step` (default `-1`), `:actions`, `:plan_fn` (both
  required, as in `replan/5`), `:plan_with_tree_fn` (required) --
  `(state, tasks, domain, blacklist, method_skip) -> plan | nil`.
  """
  @spec replan_incremental(map(), [call()], [term()], term(), SolTree.t(), keyword()) :: %{
          simulate: simulate_result(),
          new_plan: [call()] | nil,
          recovered: boolean(),
          blacklist: MapSet.t(String.t())
        }
  def replan_incremental(init_state, original_plan, original_tasks, domain, sol_tree, opts) do
    fail_step = Keyword.get(opts, :fail_step, -1)
    actions = Keyword.fetch!(opts, :actions)
    plan_fn = Keyword.fetch!(opts, :plan_fn)
    plan_with_tree_fn = Keyword.fetch!(opts, :plan_with_tree_fn)

    sim = simulate_to_fail_step(init_state, original_plan, actions, fail_step)

    if sim.fail_step < 0 do
      %{simulate: sim, new_plan: original_plan, recovered: true, blacklist: MapSet.new()}
    else
      blacklist = MapSet.new([call_key(Enum.at(original_plan, sim.fail_step))])

      ancestor =
        if sim.fail_step < length(sol_tree.action_nodes) do
          action_node_id = Enum.at(sol_tree.action_nodes, sim.fail_step)
          SolTree.nearest_retryable_ancestor(sol_tree, action_node_id, task_methods(domain))
        else
          nil
        end

      case ancestor do
        nil ->
          replan_state = sim.state || init_state
          new_plan = plan_fn.(replan_state, original_tasks, domain, blacklist)
          %{simulate: sim, new_plan: new_plan, recovered: new_plan != nil, blacklist: blacklist}

        ancestor_id ->
          replan_with_ancestor(
            init_state,
            original_plan,
            original_tasks,
            domain,
            sol_tree,
            ancestor_id,
            sim,
            blacklist,
            plan_with_tree_fn,
            actions
          )
      end
    end
  end

  # Domain is opaque to this module (injected planner owns its shape) --
  # `nearest_retryable_ancestor/3` only needs a `%{name => [alt, ...]}`
  # map, so accept either that map directly or a struct/map exposing it
  # under a `:task_methods` key (matching `TwDomain.task_methods`).
  defp task_methods(%{task_methods: task_methods}), do: task_methods
  defp task_methods(task_methods) when is_map(task_methods), do: task_methods

  defp replan_with_ancestor(
         init_state,
         original_plan,
         original_tasks,
         domain,
         sol_tree,
         ancestor_id,
         sim,
         blacklist,
         plan_with_tree_fn,
         actions
       ) do
    prefix_len = SolTree.prefix_length(sol_tree, ancestor_id)

    replan_state =
      if prefix_len > 0 do
        prefix = Enum.take(original_plan, prefix_len)
        simulate(init_state, prefix, actions).state || init_state
      else
        init_state
      end

    ancestor_node = Map.fetch!(sol_tree.nodes, ancestor_id)
    ancestor_call = {ancestor_node.name, ancestor_node.args}
    skip = %{call_key(ancestor_call) => MapSet.new([ancestor_node.method_idx])}

    case plan_with_tree_fn.(replan_state, original_tasks, domain, blacklist, skip) do
      nil ->
        %{simulate: sim, new_plan: nil, recovered: false, blacklist: blacklist}

      suffix ->
        full_plan = Enum.take(original_plan, prefix_len) ++ suffix
        %{simulate: sim, new_plan: full_plan, recovered: true, blacklist: blacklist}
    end
  end
end

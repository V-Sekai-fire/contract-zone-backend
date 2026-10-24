# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.Explain do
  @moduledoc """
  Hand-ported from `standalone/tw_explain.hpp` into plain Elixir --
  builds an inspectable explanation tree for a solved plan (from a
  `Uro.Planner.SolTree`, RFD66606-0029) or a `no_plan` outcome (from a task
  list + domain). No JSON string boundary: returns a plain map, since
  nothing here crosses a language boundary anymore.

  A task is `{:call, name, args}` | `{:goal, bindings}` |
  `{:multi_goal, bindings}`, each binding `{var, key, desired}` --
  matching `Uro.Planner.SolTree.Node`'s own kind atoms
  (`:root`/`:task`/`:action`/`:goal`/`:multi_goal`). `domain` is
  `%{actions: map_or_set, task_methods: map}`, duck-typed the same way
  as `Uro.Planner.Replan.task_methods/1` -- this module has no opinion
  on how a real domain is represented, only that it can answer
  "is this name a known action/task".
  """

  alias Uro.Planner.SolTree

  @doc "The plain-string name of a `Uro.Planner.SolTree.Node` kind atom."
  @spec node_kind_name(SolTree.kind()) :: String.t()
  def node_kind_name(:root), do: "root"
  def node_kind_name(:task), do: "task"
  def node_kind_name(:action), do: "action"
  def node_kind_name(:goal), do: "goal"
  def node_kind_name(:multi_goal), do: "multigoal"

  @doc "`{name, args}` -> `[name | args]`."
  @spec call_to_list({String.t(), [term()]}) :: [term()]
  def call_to_list({name, args}), do: [name | args]

  @doc "A single `Uro.Planner.SolTree.Node` as a plain map, keyed by its tree id."
  @spec soltree_node_to_map(SolTree.Node.t(), non_neg_integer()) :: map()
  def soltree_node_to_map(%SolTree.Node{} = node, id) do
    %{id: id, kind: node_kind_name(node.kind), parent: node.parent}
    |> maybe_put(:name, node.name, &(&1 not in [nil, ""]))
    |> maybe_put(:args, node.args, &(&1 != []))
    |> maybe_put(:method_idx, node.method_idx, &(&1 >= 0))
    |> maybe_put(:plan_step, node.plan_step, &(&1 >= 0))
    |> maybe_put(:first_step, node.first_step, &(&1 >= 0))
    |> Map.put(:children, node.children)
  end

  defp maybe_put(map, key, value, keep?) do
    if keep?.(value), do: Map.put(map, key, value), else: map
  end

  @doc """
  The full explanation map for a solved plan: mode/status, the plan
  steps (as `[name | args]` lists), every solution-tree node, and the
  action-node id order.
  """
  @spec solution_tree_map(SolTree.t(), [{String.t(), [term()]}]) :: map()
  def solution_tree_map(%SolTree{} = tree, plan) do
    nodes =
      for id <- 0..(tree.size - 1)//1 do
        soltree_node_to_map(Map.fetch!(tree.nodes, id), id)
      end

    %{
      mode: "native",
      status: "ok",
      plan_steps: Enum.map(plan, &call_to_list/1),
      solution_tree: nodes,
      action_nodes: tree.action_nodes
    }
  end

  defp domain_actions(%{actions: actions}), do: actions
  defp domain_task_methods(%{task_methods: task_methods}), do: task_methods

  defp has_action?(domain, name) do
    case domain_actions(domain) do
      %MapSet{} = set -> MapSet.member?(set, name)
      map when is_map(map) -> Map.has_key?(map, name)
    end
  end

  defp has_task?(domain, name), do: Map.has_key?(domain_task_methods(domain), name)

  @doc "A single task-list entry as a plain map, for a `no_plan` failure tree."
  @spec failure_task_map({atom(), term()}, map(), non_neg_integer()) :: map()
  def failure_task_map({:call, name, args}, domain, index) do
    symbol_type =
      cond do
        has_action?(domain, name) -> "action"
        has_task?(domain, name) -> "method"
        true -> "unknown"
      end

    %{
      index: index,
      kind: "task_call",
      name: name,
      args: args,
      resolvable: has_action?(domain, name) or has_task?(domain, name),
      symbol_type: symbol_type
    }
  end

  def failure_task_map({:goal, bindings}, _domain, index) do
    %{index: index, kind: "goal", bindings: bindings_to_maps(bindings)}
  end

  def failure_task_map({:multi_goal, bindings}, _domain, index) do
    %{index: index, kind: "multigoal", bindings: bindings_to_maps(bindings)}
  end

  defp bindings_to_maps(bindings) do
    Enum.map(bindings, fn {var, key, desired} -> %{var: var, key: key, desired: desired} end)
  end

  @doc "The full explanation map for a `no_plan` outcome."
  @spec no_plan_explain_map([term()], map()) :: map()
  def no_plan_explain_map(tasks, domain) do
    failure_tree =
      tasks
      |> Enum.with_index()
      |> Enum.map(fn {task, index} -> failure_task_map(task, domain, index) end)

    %{
      status: "no_plan",
      explain: %{
        mode: "native",
        status: "no_plan",
        summary: "planner returned no_plan",
        failure_tree: failure_tree
      }
    }
  end
end

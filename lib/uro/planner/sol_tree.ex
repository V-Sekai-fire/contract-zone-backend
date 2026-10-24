# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.SolTree do
  @moduledoc """
  Hand-ported from `standalone/tw_soltree.hpp` into plain Elixir --
  same reasoning as `Uro.LoopCore`/`Uro.Planner.Temporal`'s ports
  (RFD66606-0026/0028): self-contained bookkeeping, not untrusted content.

  Records the HTN method-choice derivation tree (D/T/A/G/M nodes, per
  IPyHOP's `sol_tree`) so incremental replan can backtrack at the exact
  choice point instead of restarting the full search. Nodes are kept in
  a `%{index => Node.t()}` map (append-only within one checkpoint/
  restore window) rather than a growable array -- `restore/2` "removes"
  nodes by dropping map keys and unlinking them from any surviving
  parent, exactly mirroring the original's `nodes.resize(cp)` plus
  parent-side `children` cleanup.

  Not yet wired to a caller -- `tw_replan.hpp` (the actual incremental
  replan search that uses this tree for backtracking) is a separate,
  not-yet-ported module. This lands as a tested, complete building
  block for that follow-on port.
  """

  defmodule Node do
    @moduledoc false
    defstruct kind: :root,
              parent: -1,
              children: [],
              name: nil,
              args: [],
              method_idx: -1,
              plan_step: -1,
              first_step: -1
  end

  defstruct nodes: %{}, size: 0, action_nodes: []

  @type kind :: :root | :task | :action | :goal | :multi_goal
  @type t :: %__MODULE__{
          nodes: %{non_neg_integer() => Node.t()},
          size: non_neg_integer(),
          action_nodes: [non_neg_integer()]
        }

  @doc "An empty tree -- the caller adds the root explicitly via add_node/5 with parent -1."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Adds a node whose parent is already in the tree (or `-1` for a root).
  Returns `{tree, node_id}`.
  """
  @spec add_node(t(), kind(), integer(), String.t() | nil, [term()], integer()) ::
          {t(), non_neg_integer()}
  def add_node(%__MODULE__{} = tree, kind, parent_id, name, args, method_idx \\ -1) do
    id = tree.size
    node = %Node{kind: kind, parent: parent_id, name: name, args: args, method_idx: method_idx}
    nodes = Map.put(tree.nodes, id, node)

    nodes =
      if parent_id >= 0 and parent_id < id do
        Map.update!(nodes, parent_id, &%{&1 | children: &1.children ++ [id]})
      else
        nodes
      end

    {%{tree | nodes: nodes, size: id + 1}, id}
  end

  @doc "Records `step` as an Action node's 0-based index in the returned plan."
  @spec set_plan_step(t(), non_neg_integer(), non_neg_integer()) :: t()
  def set_plan_step(%__MODULE__{} = tree, id, step),
    do: %{tree | nodes: Map.update!(tree.nodes, id, &%{&1 | plan_step: step})}

  @doc "Records the plan_step of a Task/Goal/MultiGoal node's leftmost Action descendant."
  @spec set_first_step(t(), non_neg_integer(), non_neg_integer()) :: t()
  def set_first_step(%__MODULE__{} = tree, id, step),
    do: %{tree | nodes: Map.update!(tree.nodes, id, &%{&1 | first_step: step})}

  @doc "Appends an Action node id to the plan-order list."
  @spec push_action_node(t(), non_neg_integer()) :: t()
  def push_action_node(%__MODULE__{} = tree, id),
    do: %{tree | action_nodes: tree.action_nodes ++ [id]}

  @doc "Snapshot: the current tree size, to roll back to later via restore/2."
  @spec checkpoint(t()) :: non_neg_integer()
  def checkpoint(%__MODULE__{size: size}), do: size

  @doc """
  Rolls back to a checkpoint: removes every node added since `cp` and
  unlinks them from any surviving parent (parents are always before
  `cp`, since a node's parent must exist before it does).
  """
  @spec restore(t(), non_neg_integer()) :: t()
  def restore(%__MODULE__{} = tree, cp) do
    removed = cp..(tree.size - 1)

    nodes =
      Enum.reduce(removed, tree.nodes, fn i, acc ->
        case Map.get(acc, i) do
          %Node{parent: p} when p >= 0 and p < cp ->
            Map.update!(acc, p, &%{&1 | children: List.delete(&1.children, i)})

          _ ->
            acc
        end
      end)

    nodes = Map.drop(nodes, Enum.to_list(removed))

    %{tree | nodes: nodes, size: cp, action_nodes: Enum.filter(tree.action_nodes, &(&1 < cp))}
  end

  @doc """
  Walks up from `node_id`; returns the first ancestor of kind
  `:task`/`:goal` that still has at least one more method alternative
  to try (per `task_methods`, a `%{name => [alternative, ...]}` map),
  or `nil` if no such ancestor exists. The root (index 0) is never
  itself a candidate -- matches the original's `while (cur > 0)`.
  """
  @spec nearest_retryable_ancestor(t(), non_neg_integer(), %{String.t() => [term()]}) ::
          non_neg_integer() | nil
  def nearest_retryable_ancestor(%__MODULE__{} = tree, node_id, task_methods) do
    tree.nodes |> Map.fetch!(node_id) |> Map.fetch!(:parent) |> find_retryable(tree, task_methods)
  end

  defp find_retryable(cur, _tree, _task_methods) when cur <= 0, do: nil

  defp find_retryable(cur, tree, task_methods) do
    node = Map.fetch!(tree.nodes, cur)

    retryable? =
      node.kind in [:task, :goal] and
        case Map.fetch(task_methods, node.name) do
          {:ok, alternatives} -> node.method_idx + 1 < length(alternatives)
          :error -> false
        end

    if retryable?, do: cur, else: find_retryable(node.parent, tree, task_methods)
  end

  @doc """
  Number of plan actions preceding the subtree rooted at `node_id` --
  the ancestor's `first_step`, or `0` if it has none (root-level).
  """
  @spec prefix_length(t(), non_neg_integer()) :: non_neg_integer()
  def prefix_length(%__MODULE__{} = tree, node_id) do
    case Map.fetch!(tree.nodes, node_id).first_step do
      fs when fs < 0 -> 0
      fs -> fs
    end
  end
end

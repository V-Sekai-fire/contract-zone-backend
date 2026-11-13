# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.ReBAC.StoredAdapter do
  @moduledoc """
  ReBAC adapter that answers from the stored tuples of `Uro.Tuples`.

  `Uro.ReBAC.ElixirAdapter` holds its edges in a list that the caller builds for each
  request. This adapter holds them in the `tuples` table, so an edge that was added stays
  until it is deleted. An edge `{subj, obj, rel}` is the tuple with subject `subj`, verb
  `rel` and object `obj`.

  ## The graph

  There is one table, so there is one graph: `new_graph/0` returns the handle `:stored`
  and creates nothing, and `add_edge/4` is a write to the table (a put, so adding an edge
  twice leaves one row). The port gives `add_edge/4` no way to return an error, so an
  edge the table refuses (an empty subject, object or relation) raises `ArgumentError`.

  ## Semantics

  They are those of the list adapter. `check_rel(graph, subj, rel, obj)` is true when,
  for `subj` or for a group it is a member of:

    * the tuple (node, `rel`, `obj`) is stored (a direct edge), or
    * `rel` is `CONTROLS` and the tuple (`obj`, `DELEGATED_TO`, node) is stored.

  Membership is transitive through `IS_MEMBER_OF`. The list adapter walks it with a fuel
  of 8, which the first node spends 1 of, so a group counts when some chain of at most 7
  memberships leads to it. Here the same set is found level by level: the groups of
  `subj`, then the groups of those, for at most 7 levels, with one query for each level
  and each node visited once. A node is within 7 memberships on some chain exactly when
  its shortest chain is at most 7 long, so the two walks reach the same nodes, and a cycle
  of memberships ends because a visited node is not visited again. One more query looks
  for the direct edge or the delegation among the nodes reached.

  The test `Uro.ReBAC.StoredAdapterTest` compares the two adapters over random edge sets
  and over chains on both sides of the fuel bound.
  """
  @behaviour Uro.Ports.ReBAC

  import Ecto.Query

  alias Uro.Repo
  alias Uro.Tuples
  alias Uro.Tuples.Tuple

  @fuel 8

  @impl true
  def new_graph, do: :stored

  @impl true
  def add_edge(graph, subj, obj, rel) do
    case Tuples.put(subj, rel, obj) do
      {:ok, _tuple} ->
        graph

      {:error, changeset} ->
        raise ArgumentError, "the edge was refused: #{inspect(changeset.errors)}"
    end
  end

  @impl true
  def check_rel(_graph, subj, rel, obj) do
    nodes = MapSet.to_list(reach([subj], MapSet.new([subj]), @fuel - 1))

    direct = from t in Tuple, where: t.subject in ^nodes and t.verb == ^rel and t.object == ^obj

    delegated =
      from t in Tuple,
        where: t.subject == ^obj and t.verb == "DELEGATED_TO" and t.object in ^nodes

    Repo.exists?(direct) or (rel == "CONTROLS" and Repo.exists?(delegated))
  end

  defp reach([], seen, _hops), do: seen
  defp reach(_frontier, seen, 0), do: seen

  defp reach(frontier, seen, hops) do
    groups =
      Repo.all(
        from t in Tuple,
          where: t.subject in ^frontier and t.verb == "IS_MEMBER_OF",
          distinct: true,
          select: t.object
      )

    next = Enum.reject(groups, &MapSet.member?(seen, &1))
    reach(next, MapSet.union(seen, MapSet.new(next)), hops - 1)
  end
end

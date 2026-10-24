# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.ReBAC.ElixirAdapter do
  @moduledoc """
  Plain-Elixir ReBAC adapter, ported from `c_src/s7/fixtures/rebac.scm`'s
  `check-base` (RFD66606-0022, Stage 4), itself ported from
  `standalone/tw_rebac.hpp`.

  Supersedes `Uro.ReBAC.SandboxAdapter` (RFD66606-0039): ReBAC graphs are
  trusted, bundled domain content, not adversarial input -- the same
  reasoning RFD66606-0026 already applied to loot/combat/progression.
  Running a direct-edge/transitive-membership graph walk through a
  custom Scheme-to-RISC-V compiler and a libriscv guest added machinery
  with no matching threat to sandbox against.

  Semantics kept: direct-edge match, transitive `IS_MEMBER_OF`
  (subject inherits its group's relations), and `CONTROLS`-via-
  `DELEGATED_TO` inversion, bounded by the same fuel=8 recursion depth
  `rebac.scm`/`tw_rebac.hpp` used. Dropped, same as before: union/
  intersection/difference/tuple_to_userset composite expressions
  (unreachable through `Uro.Ports.ReBAC.check_rel/4`, which only ever
  builds a `{"type":"base",...}` expr).
  """
  @behaviour Uro.Ports.ReBAC

  @fuel 8

  @impl true
  def new_graph, do: []

  @impl true
  def add_edge(graph, subj, obj, rel), do: [{subj, obj, rel} | graph]

  @impl true
  def check_rel(graph, subj, rel, obj), do: check_base(graph, subj, rel, obj, @fuel)

  defp check_base(_graph, _subj, _rel, _obj, fuel) when fuel < 1, do: false

  defp check_base(graph, subj, rel, obj, fuel) do
    find_direct(graph, subj, rel, obj) or
      find_member_transitive(graph, graph, subj, rel, obj, fuel) or
      (rel == "CONTROLS" and find_controls_delegation(graph, subj, obj))
  end

  defp find_direct(graph, subj, rel, obj) do
    Enum.any?(graph, fn {s, o, r} -> s == subj and r == rel and o == obj end)
  end

  defp find_member_transitive(graph, all_edges, subj, rel, obj, fuel) do
    graph
    |> Enum.filter(fn {s, _o, r} -> s == subj and r == "IS_MEMBER_OF" end)
    |> Enum.any?(fn {_s, o, _r} -> check_base(all_edges, o, rel, obj, fuel - 1) end)
  end

  defp find_controls_delegation(graph, subj, obj) do
    Enum.any?(graph, fn {s, o, r} -> s == obj and r == "DELEGATED_TO" and o == subj end)
  end
end

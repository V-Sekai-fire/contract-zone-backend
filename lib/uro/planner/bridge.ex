# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.Bridge do
  @moduledoc """
  Hand-ported from `standalone/tw_bridge.hpp` into plain Elixir --
  same reasoning as the other RFD66606-0026/0028/0029/0030/0032/0033/0034
  ports: string-formatting + regex extraction + a trust gate, no
  untrusted content.

  No JSON string boundary: facts/plan/state/entities arrive as plain
  Elixir data (lists of maps, plain maps, lists of strings) since
  nothing crosses a language boundary anymore.

  `parse_relation_edges/2` does not build a `Uro.ReBAC` graph handle
  directly -- `Uro.ReBAC`'s `new_graph/0` returns an opaque handle
  (native NIF resource or sandbox program handle) that this module has
  no business constructing or introspecting. Instead it returns plain
  `{subject, relation, object}` triples; a caller who wants a real
  ReBAC graph can fold `Uro.ReBAC.add_edge/4` over the result.

  One faithful quirk preserved from the original: `relation_keywords/0`
  is keyed by the *first word* of the matched verb phrase, so multi-word
  phrases whose relation keyword isn't the first word --
  `"has capability"` (first word `"has"`) and `"is member of"` (first
  word `"is"`) -- never actually match any keyword and are silently
  dropped. This reads as a pre-existing bug in the original, not
  something this port's job to fix.
  """

  @relation_keywords %{
    "owns" => :owns,
    "controls" => :controls,
    "delegated" => :delegated_to,
    "delegates" => :delegated_to,
    "capable" => :has_capability,
    "capability" => :has_capability,
    "member" => :is_member_of,
    "belongs" => :is_member_of,
    "supervises" => :supervisor_of,
    "supervisor" => :supervisor_of,
    "partner" => :partner_of
  }

  @relation_regex ~r/(\w[\w\s]*?)\s+(owns|controls|delegated to|delegates to|has capability|is member of|belongs to|supervises|partner of)\s+([\w][\w\s]*?)(?:\.|$)/iu

  @doc "Canonical text for a state/goal variable binding: \"var arg val\"."
  @spec binding_content(String.t(), String.t(), String.t()) :: String.t()
  def binding_content(var, arg, val), do: "#{var} #{arg} #{val}"

  @doc """
  Parses relation sentences out of `facts` (a list of
  `%{"content" => ..., "trust_score" => ...}`-shaped maps) into
  `{subject, relation, object}` triples. Facts below `trust_threshold`
  (default `0.5`) are skipped; facts with no numeric `trust_score` are
  kept (matching the original's "only gate when the field is present
  and numeric" behavior).
  """
  @spec parse_relation_edges([map()], number()) :: [{String.t(), atom(), String.t()}]
  def parse_relation_edges(facts, trust_threshold \\ 0.5) do
    facts
    |> Enum.filter(&trusted?(&1, trust_threshold))
    |> Enum.flat_map(fn fact ->
      case Map.get(fact, "content") do
        content when is_binary(content) -> extract_edges(content)
        _ -> []
      end
    end)
  end

  defp trusted?(fact, threshold) do
    case Map.get(fact, "trust_score") do
      score when is_number(score) -> score >= threshold
      _ -> true
    end
  end

  defp extract_edges(content) do
    @relation_regex
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.flat_map(fn [subj, verb, obj] ->
      first_word = verb |> String.downcase() |> String.split(" ", parts: 2) |> hd()

      case Map.fetch(@relation_keywords, first_word) do
        {:ok, rel} -> [{String.trim_trailing(subj), rel, String.trim_trailing(obj)}]
        :error -> []
      end
    end)
  end

  @doc """
  Returns the unique inner (argument) keys across every non-private,
  non-rigid variable binding in `state` (`%{var_name => %{arg => val}}`),
  in first-seen order. Skips `var_name`s that are empty, start with
  `_`, or are `"__name__"`/`"rigid"`; skips `arg`s that start with
  `"rigid"`.
  """
  @spec extract_state_entities(map()) :: [String.t()]
  def extract_state_entities(state) when is_map(state) do
    state
    |> Enum.reject(fn {var_name, bindings} -> skip_var?(var_name) or not is_map(bindings) end)
    |> Enum.flat_map(fn {_var_name, bindings} -> Map.keys(bindings) end)
    |> Enum.reject(&String.starts_with?(&1, "rigid"))
    |> Enum.uniq()
  end

  defp skip_var?(""), do: true
  defp skip_var?("_" <> _), do: true
  defp skip_var?("__name__"), do: true
  defp skip_var?("rigid"), do: true
  defp skip_var?(_), do: false

  @doc """
  Builds `%{"content" => ..., "category" => "planning", "tags" => domain}`
  entries for storing a plan result: one summary fact (step count +
  up to 5 entity names) plus one fact per plan step (up to 20), each
  `plan` step being `{action_name, args}`.
  """
  @spec plan_result_contents([{String.t(), [term()]}], String.t(), [String.t()]) :: [map()]
  def plan_result_contents(plan, domain, entities) do
    entity_names = entities |> Enum.filter(&is_binary/1) |> Enum.take(5) |> Enum.join(", ")

    summary = %{
      "content" => "Plan for #{domain}: #{length(plan)} steps involving #{entity_names}.",
      "category" => "planning",
      "tags" => domain
    }

    step_facts =
      plan
      |> Enum.take(20)
      |> Enum.with_index(1)
      |> Enum.map(fn {{action_name, args}, i} ->
        args_str = Enum.map_join(args, ", ", &to_string/1)

        %{
          "content" => "Plan step #{i}: #{action_name}(#{args_str}) in #{domain}.",
          "category" => "planning",
          "tags" => domain
        }
      end)

    [summary | step_facts]
  end

  @doc """
  Builds a `%{"content" => "var arg val", "category" => category, "tags" => domain}`
  entry for every `(var, arg, val)` triple in `state`
  (`%{var_name => %{arg => val}}`), skipping the same private/rigid
  `var_name`s as `extract_state_entities/1` -- but, matching the
  original exactly, NOT skipping `rigid`-prefixed `arg` names here.
  """
  @spec state_bindings_contents(map(), String.t(), String.t()) :: [map()]
  def state_bindings_contents(state, domain, category) when is_map(state) do
    state
    |> Enum.reject(fn {var_name, bindings} -> skip_var?(var_name) or not is_map(bindings) end)
    |> Enum.flat_map(fn {var_name, bindings} ->
      Enum.map(bindings, fn {arg, val} ->
        %{
          "content" => binding_content(var_name, arg, to_string(val)),
          "category" => category,
          "tags" => domain
        }
      end)
    end)
  end
end

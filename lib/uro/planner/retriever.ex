# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.Retriever do
  @moduledoc """
  Hand-ported from `standalone/tw_retriever.hpp` into plain Elixir --
  same reasoning as the other RFD66606-0026/0028/0029/0030/0032 ports: pure
  scoring/ranking math, no untrusted content, depends only on
  `Uro.Planner.HRR` (RFD66606-0032).

  The original took candidates as a JSON string because it crossed a
  NIF boundary; here candidates are plain lists of string-keyed maps
  (the shape `Jason.decode!/1` already produces) -- no JSON
  encode/decode step is needed since nothing crosses a language
  boundary anymore.
  """

  alias Uro.Planner.HRR

  @strip_chars String.graphemes(".,;:!?\"'()[]{}#@<>")

  @doc "Lowercase + whitespace-split + strip leading/trailing punctuation, deduped."
  @spec tokenize(String.t()) :: MapSet.t(String.t())
  def tokenize(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&strip_punct(String.downcase(&1)))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp strip_punct(word) do
    word
    |> String.graphemes()
    |> Enum.drop_while(&(&1 in @strip_chars))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in @strip_chars))
    |> Enum.reverse()
    |> Enum.join()
  end

  @doc "Jaccard similarity between two token sets. 0.0 if either is empty."
  @spec jaccard(MapSet.t(String.t()), MapSet.t(String.t())) :: float()
  def jaccard(a, b) do
    if Enum.empty?(a) or Enum.empty?(b) do
      0.0
    else
      intersection = MapSet.intersection(a, b) |> MapSet.size()
      union_size = MapSet.size(a) + MapSet.size(b) - intersection
      if union_size > 0, do: intersection / union_size, else: 0.0
    end
  end

  @doc "0.5^(age_days / half_life_days); 1.0 if disabled or age is negative."
  @spec temporal_decay(number(), number()) :: float()
  def temporal_decay(age_days, half_life_days) do
    if half_life_days <= 0.0 or age_days < 0.0 do
      1.0
    else
      :math.pow(0.5, age_days / half_life_days)
    end
  end

  defp get_str(map, key, default \\ ""), do: Map.get(map, key, default) || default
  defp get_dbl(map, key, default \\ 0.0), do: Map.get(map, key, default) || default

  @doc """
  Hybrid keyword/HRR relevance scoring against `query_text` +
  `query_hrr_bytes` (float64-little-endian phase bytes). Returns
  candidates sorted by descending score, each augmented with a
  `"score"` key and stripped of `"hrr_vector"`.
  """
  @spec score_candidates([map()], String.t(), binary(), number(), number(), number(), number()) ::
          [map()]
  def score_candidates(
        candidates,
        query_text,
        query_hrr_bytes,
        fts_w,
        jaccard_w,
        hrr_w,
        half_life_days
      ) do
    query_vec = HRR.bytes_to_phases(query_hrr_bytes)
    query_tokens = tokenize(query_text)

    candidates
    |> Enum.map(fn item ->
      content = get_str(item, "content")
      tags = get_str(item, "tags")
      trust = get_dbl(item, "trust_score", 0.5)
      fts_rank = get_dbl(item, "fts_rank")
      age_days = get_dbl(item, "age_days", -1.0)

      all_tokens = MapSet.union(tokenize(content), tokenize(tags))
      jac = jaccard(query_tokens, all_tokens)

      hrr_sim =
        case Map.get(item, "hrr_vector") do
          hv when is_binary(hv) and hrr_w > 0.0 and query_vec != [] and byte_size(hv) > 0 ->
            fact_vec = HRR.bytes_to_phases(hv)
            if fact_vec == [], do: 0.5, else: (HRR.similarity(query_vec, fact_vec) + 1.0) / 2.0

          _ ->
            0.5
        end

      relevance = fts_w * fts_rank + jaccard_w * jac + hrr_w * hrr_sim
      decay = temporal_decay(age_days, half_life_days)
      score = relevance * trust * decay

      item |> Map.delete("hrr_vector") |> Map.put("score", score)
    end)
    |> Enum.sort_by(& &1["score"], :desc)
  end

  @doc """
  Exact algebraic extraction: `unbind(binding_vector, entity_vector) ~= content`.
  Returns candidates sorted descending, each augmented with `"score"`
  and stripped of `"binding_vector"`.
  """
  @spec probe_score([map()], binary(), pos_integer()) :: [map()]
  def probe_score(candidates, entity_hrr_bytes, dim) do
    entity_vec = HRR.bytes_to_phases(entity_hrr_bytes)

    candidates
    |> Enum.map(fn item ->
      content = get_str(item, "content")
      trust = get_dbl(item, "trust_score", 0.5)

      hrr_sim =
        case Map.get(item, "binding_vector") do
          bv when is_binary(bv) and entity_vec != [] ->
            binding = HRR.bytes_to_phases(bv)

            if binding == [] do
              0.5
            else
              recovered = HRR.unbind(binding, entity_vec)
              content_vec = HRR.encode_text(content, dim)
              HRR.similarity(recovered, content_vec)
            end

          _ ->
            0.5
        end

      score = (hrr_sim + 1.0) / 2.0 * trust
      item |> Map.delete("binding_vector") |> Map.put("score", score)
    end)
    |> Enum.sort_by(& &1["score"], :desc)
  end

  @doc """
  Reasoning score: encodes `content` fresh per candidate, binds/unbinds
  against each entity vector on the fly, and takes the minimum
  similarity across entities (AND semantics). Keeps every original key
  (no vector field to strip here).
  """
  @spec reason_score([map()], [binary()], pos_integer()) :: [map()]
  def reason_score(_candidates, [], _dim), do: []

  def reason_score(candidates, entity_hrr_bytes_list, dim) do
    entity_vecs = Enum.map(entity_hrr_bytes_list, &HRR.bytes_to_phases/1)

    candidates
    |> Enum.map(fn item ->
      content = get_str(item, "content")
      trust = get_dbl(item, "trust_score", 0.5)
      content_vec = HRR.encode_text(content, dim)

      min_sim =
        entity_vecs
        |> Enum.reject(&(&1 == []))
        |> Enum.map(fn ev ->
          bound = HRR.bind(content_vec, ev)
          recovered = HRR.unbind(bound, ev)
          HRR.similarity(recovered, content_vec)
        end)
        |> case do
          [] -> 1.0
          sims -> Enum.min(sims)
        end

      score = (min_sim + 1.0) / 2.0 * trust
      Map.put(item, "score", score)
    end)
    |> Enum.sort_by(& &1["score"], :desc)
  end
end

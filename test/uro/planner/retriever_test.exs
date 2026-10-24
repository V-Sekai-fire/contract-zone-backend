# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.RetrieverTest do
  @moduledoc """
  Verification for the plain-Elixir port of `standalone/tw_retriever.hpp`
  (RFD66606-0033).
  """
  use ExUnit.Case, async: true

  alias Uro.Planner.{HRR, Retriever}

  describe "tokenize/1" do
    test "lowercases, splits, strips punctuation, and dedupes" do
      assert Retriever.tokenize("The Cat, the CAT! (sat).") ==
               MapSet.new(["the", "cat", "sat"])
    end
  end

  describe "jaccard/2" do
    test "0.0 when either set is empty" do
      assert Retriever.jaccard(MapSet.new(), MapSet.new(["a"])) == 0.0
      assert Retriever.jaccard(MapSet.new(["a"]), MapSet.new()) == 0.0
    end

    test "intersection over union" do
      a = MapSet.new(["a", "b", "c"])
      b = MapSet.new(["b", "c", "d"])
      assert_in_delta Retriever.jaccard(a, b), 2 / 4, 1.0e-9
    end
  end

  describe "temporal_decay/2" do
    test "1.0 when half_life is non-positive or age is negative" do
      assert Retriever.temporal_decay(5, 0) == 1.0
      assert Retriever.temporal_decay(-1, 10) == 1.0
    end

    test "0.5 at exactly one half-life" do
      assert_in_delta Retriever.temporal_decay(10, 10), 0.5, 1.0e-9
    end
  end

  describe "score_candidates/7" do
    test "ranks by relevance*trust*decay, strips hrr_vector, sorts descending" do
      dim = 64
      query_vec = HRR.encode_text("red apple", dim)
      matching_bytes = HRR.phases_to_bytes(HRR.encode_text("red apple pie", dim))
      unrelated_bytes = HRR.phases_to_bytes(HRR.encode_text("distant galaxy", dim))

      candidates = [
        %{
          "content" => "red apple pie",
          "tags" => "fruit",
          "trust_score" => 1.0,
          "fts_rank" => 0.0,
          "hrr_vector" => matching_bytes
        },
        %{
          "content" => "distant galaxy",
          "tags" => "space",
          "trust_score" => 1.0,
          "fts_rank" => 0.0,
          "hrr_vector" => unrelated_bytes
        }
      ]

      [best, worst] =
        Retriever.score_candidates(
          candidates,
          "red apple",
          HRR.phases_to_bytes(query_vec),
          0.0,
          0.5,
          0.5,
          0
        )

      assert best["content"] == "red apple pie"
      assert worst["content"] == "distant galaxy"
      refute Map.has_key?(best, "hrr_vector")
      assert best["score"] > worst["score"]
    end

    test "defaults trust_score to 0.5 and fts_rank to 0.0 when absent" do
      [result] =
        Retriever.score_candidates(
          [%{"content" => "hello"}],
          "hello",
          <<>>,
          0.0,
          1.0,
          0.0,
          0
        )

      assert result["score"] > 0.0
    end
  end

  describe "probe_score/3" do
    test "high similarity when binding_vector correctly encodes entity+content" do
      dim = 64
      entity_vec = HRR.encode_atom("weather", dim)
      content = "sky is blue"
      binding = HRR.bind(HRR.encode_text(content, dim), entity_vec)

      candidates = [
        %{
          "content" => content,
          "trust_score" => 1.0,
          "binding_vector" => HRR.phases_to_bytes(binding)
        }
      ]

      [result] = Retriever.probe_score(candidates, HRR.phases_to_bytes(entity_vec), dim)
      assert result["score"] > 0.9
      refute Map.has_key?(result, "binding_vector")
    end

    test "defaults to a neutral 0.5 similarity when no binding_vector is present" do
      [result] = Retriever.probe_score([%{"content" => "x", "trust_score" => 1.0}], <<>>, 64)
      assert_in_delta result["score"], 0.75, 1.0e-9
    end
  end

  describe "reason_score/3" do
    test "empty entity list yields an empty result" do
      assert Retriever.reason_score([%{"content" => "x"}], [], 64) == []
    end

    test "takes the minimum similarity across entities (AND semantics)" do
      dim = 64
      candidates = [%{"content" => "hello world", "trust_score" => 1.0}]
      entity_bytes = [HRR.phases_to_bytes(HRR.encode_atom("a", dim))]

      [result] = Retriever.reason_score(candidates, entity_bytes, dim)
      assert result["score"] > 0.0
      assert result["content"] == "hello world"
    end
  end
end

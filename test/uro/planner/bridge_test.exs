# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.BridgeTest do
  @moduledoc """
  Verification for the plain-Elixir port of `standalone/tw_bridge.hpp`
  (RFD66606-0035).
  """
  use ExUnit.Case, async: true

  alias Uro.Planner.Bridge

  describe "binding_content/3" do
    test "joins var, arg, val with spaces" do
      assert Bridge.binding_content("robot1", "location", "kitchen") ==
               "robot1 location kitchen"
    end
  end

  describe "parse_relation_edges/2" do
    test "extracts a simple owns relation" do
      facts = [%{"content" => "Alice owns the warehouse."}]
      assert Bridge.parse_relation_edges(facts) == [{"Alice", :owns, "the warehouse"}]
    end

    test "extracts multiple keyword relations across facts" do
      facts = [
        %{"content" => "Bob controls the reactor."},
        %{"content" => "Carol supervises Dave."}
      ]

      assert Bridge.parse_relation_edges(facts) == [
               {"Bob", :controls, "the reactor"},
               {"Carol", :supervisor_of, "Dave"}
             ]
    end

    test "skips facts below the trust threshold" do
      facts = [
        %{"content" => "Alice owns the warehouse.", "trust_score" => 0.2},
        %{"content" => "Bob controls the reactor.", "trust_score" => 0.9}
      ]

      assert Bridge.parse_relation_edges(facts, 0.5) == [{"Bob", :controls, "the reactor"}]
    end

    test "keeps facts with no trust_score field at all" do
      facts = [%{"content" => "Alice owns the warehouse."}]
      assert Bridge.parse_relation_edges(facts, 0.9) == [{"Alice", :owns, "the warehouse"}]
    end

    test "silently drops multi-word phrases whose keyword isn't the first word (preserved quirk)" do
      facts = [%{"content" => "Alice has capability flying."}]
      assert Bridge.parse_relation_edges(facts) == []
    end

    test "returns nothing for content with no matching verb" do
      facts = [%{"content" => "The weather is nice today."}]
      assert Bridge.parse_relation_edges(facts) == []
    end
  end

  describe "extract_state_entities/1" do
    test "collects unique argument keys, skipping private/internal/rigid vars" do
      state = %{
        "location" => %{"robot1" => "kitchen", "robot2" => "hall"},
        "_private" => %{"x" => "y"},
        "__name__" => %{"x" => "y"},
        "rigid" => %{"x" => "y"},
        "holding" => %{"robot1" => "cup"}
      }

      assert Enum.sort(Bridge.extract_state_entities(state)) == ["robot1", "robot2"]
    end

    test "skips rigid-prefixed argument names" do
      state = %{"location" => %{"rigid_wall" => "north", "robot1" => "kitchen"}}
      assert Bridge.extract_state_entities(state) == ["robot1"]
    end
  end

  describe "plan_result_contents/3" do
    test "builds a summary fact plus one fact per step, capped at 20 steps" do
      plan = [{"move", ["robot1", "kitchen"]}, {"pickup", ["robot1", "cup"]}]
      results = Bridge.plan_result_contents(plan, "household", ["robot1", "cup"])

      assert length(results) == 3
      [summary, step1, step2] = results

      assert summary["content"] == "Plan for household: 2 steps involving robot1, cup."
      assert summary["category"] == "planning"
      assert summary["tags"] == "household"

      assert step1["content"] == "Plan step 1: move(robot1, kitchen) in household."
      assert step2["content"] == "Plan step 2: pickup(robot1, cup) in household."
    end

    test "caps entity names at 5 and steps at 20" do
      plan = for i <- 1..25, do: {"action#{i}", []}
      entities = for i <- 1..10, do: "e#{i}"

      results = Bridge.plan_result_contents(plan, "d", entities)
      [summary | steps] = results

      assert summary["content"] == "Plan for d: 25 steps involving e1, e2, e3, e4, e5."
      assert length(steps) == 20
    end
  end

  describe "state_bindings_contents/3" do
    test "builds one fact per (var, arg, val) triple, without skipping rigid args" do
      state = %{
        "location" => %{"robot1" => "kitchen", "rigid_wall" => "north"},
        "_private" => %{"x" => "y"}
      }

      results = Bridge.state_bindings_contents(state, "household", "state")

      assert length(results) == 2
      contents = Enum.map(results, & &1["content"]) |> Enum.sort()
      assert contents == ["location rigid_wall north", "location robot1 kitchen"]
      assert Enum.all?(results, &(&1["category"] == "state"))
      assert Enum.all?(results, &(&1["tags"] == "household"))
    end
  end
end

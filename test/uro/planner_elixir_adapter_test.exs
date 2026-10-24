# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.ElixirAdapterTest do
  @moduledoc """
  Regression suite for `Uro.Planner.ElixirAdapter` (plain Elixir,
  RFD66606-0040 -- the whole HTN search AND domain evaluation, not just a
  search-only subset).

  These cases originally ran through both `Uro.Planner.TaskweftAdapter`
  (the native `tw_loader.hpp` + `tw_planner.hpp` NIF) and then
  `Uro.Planner.SandboxAdapter` (compiled Scheme in the libriscv guest,
  RFD66606-0023), asserting agreement, before both were retired (RFD66606-0038,
  RFD66606-0039) in favor of this direct port. Each case just pins the plan
  that comparison already proved correct. Every domain uses the CURRENT
  loader schema (variables/actions/methods/todo_list), not the stale
  `priv/domains/*.jsonld` schema (a separate, pre-existing bug per
  RFD66606-0023's Context section).
  """
  use ExUnit.Case, async: true

  alias Uro.Planner.ElixirAdapter

  defp run(domain_json) do
    {:ok, ElixirAdapter.plan(domain_json)}
  rescue
    _ -> :no_plan
  end

  defp plan_for(domain_json) do
    case run(domain_json) do
      :no_plan -> :no_plan
      {:ok, json} -> Jason.decode!(json)
    end
  end

  @behave_domain """
  {
    "variables": [
      {"name": "threat", "init": {"near": true}},
      {"name": "loc", "init": {"pos": "open"}}
    ],
    "actions": {
      "flee": {"body": [{"pointer/set": "/loc/pos", "value": "shelter"}]},
      "recover": {"body": [{"pointer/set": "/threat/near", "value": false}]},
      "drift": {"body": []}
    },
    "methods": {
      "behave": {
        "alternatives": [
          {"check": [{"eval": {"type": "get", "pointer": "/threat/near"}}],
           "subtasks": [["flee"], ["recover"]]},
          {"subtasks": [["drift"]]}
        ]
      }
    },
    "todo_list": [["behave"]]
  }
  """

  test "compound task picks the checked alternative when threat is near" do
    assert [["flee"], ["recover"]] = plan_for(@behave_domain)
  end

  test "compound task falls back when the checked alternative's guard fails" do
    domain = String.replace(@behave_domain, ~s("near": true), ~s("near": false))
    assert [["drift"]] = plan_for(domain)
  end

  test "goal with no registered method is a clean no-plan" do
    domain = """
    {
      "variables": [{"name": "loc", "init": {"pos": "open"}}],
      "todo_list": [{"goal": [{"pointer": "/loc/pos", "eq": "shelter"}]}]
    }
    """

    assert :no_plan = plan_for(domain)
  end

  test "multigoal backtracks over both unmet bindings" do
    domain = """
    {
      "variables": [
        {"name": "threat", "init": {"near": true}},
        {"name": "loc", "init": {"pos": "open"}}
      ],
      "actions": {
        "flee": {"body": [{"pointer/set": "/loc/pos", "value": "shelter"}]},
        "recover": {"body": [{"pointer/set": "/threat/near", "value": false}]}
      },
      "methods": {
        "threat": {"alternatives": [{"subtasks": [["recover"]]}]},
        "loc": {"alternatives": [{"subtasks": [["flee"]]}]}
      },
      "todo_list": [
        {"multigoal": {"threat": {"near": false}, "loc": {"pos": "shelter"}}}
      ]
    }
    """

    assert [["recover"], ["flee"]] = plan_for(domain)
  end

  test "a goal whose method under-satisfies it forces a retry (splice-order proof)" do
    domain = """
    {
      "variables": [{"name": "counter", "init": {"val": 0}}],
      "actions": {
        "bump": {
          "params": ["cur"],
          "bind": [{"name": "cur", "pointer": "/counter/val"}],
          "body": [
            {"pointer/set": "/counter/val",
             "value": {"type": "add", "a": "{cur}", "b": 1}}
          ]
        }
      },
      "methods": {
        "counter": {"alternatives": [{"subtasks": [["bump"]]}]}
      },
      "todo_list": [{"goal": [{"pointer": "/counter/val", "eq": 3}]}]
    }
    """

    assert [["bump"], ["bump"], ["bump"]] = plan_for(domain)
  end

  test "a long flat sequence of independent primitive actions costs no branching fuel" do
    calls = List.duplicate(~s(["drift"]), 50) |> Enum.join(", ")

    domain = """
    {
      "actions": {"drift": {"body": []}},
      "todo_list": [#{calls}]
    }
    """

    assert plan = plan_for(domain)
    assert length(plan) == 50
  end

  describe "scan methods (Stage 5B, RFD 0039/0040)" do
    test "first branch wins for every key that satisfies its check before the next branch runs" do
      domain = """
      {
        "variables": [
          {"name": "npcs", "init": {"n1": "hostile"}}
        ],
        "actions": {
          "attack": {"params": ["target"], "body": []},
          "greet": {"params": ["target"], "body": []}
        },
        "methods": {
          "process_npcs": {
            "scan": {
              "over": "npcs",
              "branches": [
                {
                  "check": [{"eval": {"type": "eq", "a": {"type": "get", "pointer": "/npcs/{_key}"}, "b": "hostile"}}],
                  "subtasks": [["attack", "{_key}"]]
                },
                {"subtasks": [["greet", "{_key}"]]}
              ]
            }
          }
        },
        "todo_list": [["process_npcs"]]
      }
      """

      assert [["attack", "n1"]] = plan_for(domain)
    end

    test "second branch is the fallback when the first branch's check fails every key" do
      domain = """
      {
        "variables": [
          {"name": "npcs", "init": {"n1": "friendly"}}
        ],
        "actions": {
          "attack": {"params": ["target"], "body": []},
          "greet": {"params": ["target"], "body": []}
        },
        "methods": {
          "process_npcs": {
            "scan": {
              "over": "npcs",
              "branches": [
                {
                  "check": [{"eval": {"type": "eq", "a": {"type": "get", "pointer": "/npcs/{_key}"}, "b": "hostile"}}],
                  "subtasks": [["attack", "{_key}"]]
                },
                {"subtasks": [["greet", "{_key}"]]}
              ]
            }
          }
        },
        "todo_list": [["process_npcs"]]
      }
      """

      assert [["greet", "n1"]] = plan_for(domain)
    end

    test "done_subtasks run once every branch fails for every key" do
      domain = """
      {
        "variables": [
          {"name": "npcs", "init": {"n1": "friendly"}}
        ],
        "actions": {
          "attack": {"params": ["target"], "body": []},
          "drift": {"body": []}
        },
        "methods": {
          "process_npcs": {
            "scan": {
              "over": "npcs",
              "branches": [
                {
                  "check": [{"eval": {"type": "eq", "a": {"type": "get", "pointer": "/npcs/{_key}"}, "b": "hostile"}}],
                  "subtasks": [["attack", "{_key}"]]
                }
              ],
              "done_subtasks": [["drift"]]
            }
          }
        },
        "todo_list": [["process_npcs"]]
      }
      """

      assert [["drift"]] = plan_for(domain)
    end

    test "empty scan variable runs done_subtasks immediately" do
      domain = """
      {
        "variables": [{"name": "npcs", "init": {}}],
        "actions": {"drift": {"body": []}},
        "methods": {
          "process_npcs": {"scan": {"over": "npcs", "branches": [], "done_subtasks": [["drift"]]}}
        },
        "todo_list": [["process_npcs"]]
      }
      """

      assert [["drift"]] = plan_for(domain)
    end

    test "recurse re-appends the named task after a successful branch" do
      # Pointers are always fixed /var/key paths (no {target}-style
      # templating -- see Uro.Planner.ElixirAdapter's moduledoc), so
      # "attack" hardcodes the one npc key this domain has instead of
      # addressing it via its own param.
      domain = """
      {
        "variables": [{"name": "npcs", "init": {"n1": "hostile"}}],
        "actions": {"attack": {"params": ["target"], "body": [{"pointer/set": "/npcs/n1", "value": "dead"}]}},
        "methods": {
          "process_npcs": {
            "scan": {
              "over": "npcs",
              "recurse": "process_npcs",
              "branches": [
                {
                  "check": [{"eval": {"type": "eq", "a": {"type": "get", "pointer": "/npcs/{_key}"}, "b": "hostile"}}],
                  "subtasks": [["attack", "{_key}"]]
                }
              ],
              "done_subtasks": []
            }
          }
        },
        "todo_list": [["process_npcs"]]
      }
      """

      assert [["attack", "n1"]] = plan_for(domain)
    end
  end
end

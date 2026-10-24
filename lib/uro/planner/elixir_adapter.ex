# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.ElixirAdapter do
  @moduledoc """
  Plain-Elixir planner adapter, ported from
  `c_src/s7/fixtures/planner.scm` (RFD66606-0023, Stage 5A/5B), itself
  ported from `standalone/tw_planner.hpp`/`tw_loader.hpp`.

  Supersedes `Uro.Planner.SandboxAdapter` (RFD66606-0039): planner domains
  are trusted, bundled content (bundled `.jsonld` files), not
  adversarial input -- the same reasoning RFD66606-0026 already applied to
  loot/combat/progression. Running the HTN search and its expression
  evaluator through a custom Scheme-to-RISC-V compiler and a libriscv
  guest added a large amount of machinery (a whole AOT compiler,
  `c_src/s7`) with no matching threat to sandbox against; this module
  is the direct, idiomatic-Elixir translation of that same Scheme
  program's semantics, with none of the guest-ABI plumbing (no atom
  interning, no tagged-list wire format, no fuel-via-ecall) -- fuel is
  now just a plain recursive counter.

  Search semantics kept, matching `tw_seek_plan`/`planner.scm` exactly:
  `TwGoal` splices `subtasks ++ [goal] ++ remaining` (re-verifies before
  `remaining` runs); `TwMultiGoal` tries EVERY unmet binding, not just
  the first; compound `TwCall` splices `subtasks ++ remaining` with no
  self-re-append; fuel is spent only on real branching decisions
  (goal/multigoal/compound-task), never on primitive-action or
  already-satisfied-goal advancement.

  Scan methods (Stage 5B) are supported with one documented narrowing
  vs. native: a scan branch's `bind` pointers are always fixed
  `/var/key` paths, never RFC 6901 `{_key}`-templated. A `"get"` node's
  KEY segment is the one exception -- `{"type":"get","pointer":
  "/npcs/{_key}"}` resolves against the current scan key at eval time,
  which is what lets a branch's `check`/`subtasks` inspect the entity
  at each key, not just its key name -- but a branch still can't use the
  current key to address a *different* var/key through a templated
  `bind`, and only a single whole-segment template is supported (no
  native-style multi-template string interpolation).

  Explicitly unsupported (raises a clear error rather than silently
  misbehaving): ReBAC-based goal bindings (`capabilities`), `enums`,
  floating-point values, and any KHR_interactivity node type beyond
  `eq`/`lt`/`add`/`sub`/`not`/`and`/`or`/`get`. State/desired/literal
  values are fixnums, booleans, or atoms only -- JSON strings are
  atomized (`String.to_atom/1`), which is safe only because domain JSON
  is trusted, author-controlled content, never arbitrary end-user
  input.

  Uses `Uro.Planner.OrderedJson`, not `Jason`, to parse the domain: a
  `multigoal`'s per-var/per-key binding order is semantically
  meaningful (it determines which binding the HTN search tries first).
  """
  @behaviour Uro.Ports.Planner

  alias Uro.Planner.OrderedJson, as: OJ

  # The name a scan method's current key is bound under in that
  # attempt's params (native's fixed "_key").
  @scan_key_name :_key

  # Entry-point fuel bound, matching tw_planner.hpp's TW_MAX_DEPTH.
  @fuel 400

  @impl true
  def plan(domain_json) do
    domain = OJ.decode!(domain_json)
    validate_keys!(domain)

    state = build_state(OJ.get(domain, "variables") || [])

    ctx = %{
      actions: build_actions_tbl(OJ.get(domain, "actions")),
      methods: build_methods_tbl(OJ.get(domain, "methods"))
    }

    tasks = build_tasks(OJ.get(domain, "todo_list") || [])

    case walk_tasks(state, tasks, @fuel, ctx) do
      # Matches Uro.Planner.TaskweftAdapter's old contract (raises on
      # no-plan) so callers didn't have to change across the RFD66606-0038
      # config-flip.
      false ->
        raise "no_plan"

      plan_tasks when is_list(plan_tasks) ->
        Jason.encode!(Enum.map(plan_tasks, &plan_step_json/1))
    end
  end

  defp plan_step_json({:call, name, args}),
    do: [Atom.to_string(name) | Enum.map(args, &to_json_value/1)]

  defp to_json_value(v) when is_atom(v) and not is_boolean(v), do: Atom.to_string(v)
  defp to_json_value(v), do: v

  # --- Top-level whitelist (mirrors the sandboxed adapter's subset) ---

  @known_keys ~w(@context @type name description version source variables actions methods todo_list)

  defp validate_keys!(domain) do
    for {key, _} <- OJ.pairs(domain), key not in @known_keys do
      raise "Uro.Planner.ElixirAdapter: unsupported domain key #{inspect(key)} " <>
              "(enums/capabilities are Stage 5C follow-on; anything else is unrecognized)"
    end
  end

  # --- State: variables -> a 2-level map (var -> key -> value). Only
  #     dict-shaped `init` is supported (a bare scalar `init` has no
  #     pointer-addressable (var,key) path to reach it from an action/
  #     method eval node anyway). ---

  defp build_state(variables) do
    Enum.reduce(variables, %{}, fn var_def, state ->
      name = OJ.get(var_def, "name")
      init = OJ.get(var_def, "init")

      unless match?({:obj, _}, init) do
        raise "Uro.Planner.ElixirAdapter: variable #{name} has a non-dict init " <>
                "(bare scalar state vars aren't pointer-addressable)"
      end

      inner = Map.new(OJ.pairs(init), fn {k, v} -> {String.to_atom(k), from_domain_value(v)} end)
      Map.put(state, String.to_atom(name), inner)
    end)
  end

  defp from_domain_value(v) when is_integer(v), do: v
  defp from_domain_value(v) when is_boolean(v), do: v
  defp from_domain_value(v) when is_binary(v), do: String.to_atom(v)

  defp from_domain_value(v) do
    raise "Uro.Planner.ElixirAdapter: unsupported value #{inspect(v)} " <>
            "(state/desired/literal values are fixnums, booleans, or atoms only -- no floats)"
  end

  # --- Actions: name -> {params, binds, body}. "actions" is a JSON
  #     object (name -> def), not an array. ---

  defp build_actions_tbl(nil), do: %{}

  defp build_actions_tbl(actions) do
    Map.new(OJ.pairs(actions), fn {name, def_} ->
      params = Enum.map(OJ.get(def_, "params") || [], &String.to_atom/1)
      binds = build_binds(OJ.get(def_, "bind") || [])
      body = Enum.map(OJ.get(def_, "body") || [], &compile_step/1)
      {String.to_atom(name), {params, binds, body}}
    end)
  end

  defp build_binds(binds) do
    Enum.map(binds, fn bind ->
      name = OJ.get(bind, "name")
      {var, key} = parse_pointer(OJ.get(bind, "pointer"))
      {String.to_atom(name), var, key}
    end)
  end

  defp compile_step(step) do
    cond do
      node = OJ.get(step, "eval") ->
        {:eval, compile_node(node)}

      ptr = OJ.get(step, "pointer/set") ->
        {var, key} = parse_pointer(ptr)
        {:set, var, key, compile_node(OJ.get(step, "value"))}

      true ->
        raise "Uro.Planner.ElixirAdapter: unsupported action body step #{inspect(step)} " <>
                "(only eval/pointer-set are implemented)"
    end
  end

  # --- Methods: name -> {:alts, [{params, binds, checks, subtasks}, ...]}
  #     | {:scan, scan_def}. "methods" is a JSON object (task name ->
  #     group), like "actions". ---

  defp build_methods_tbl(nil), do: %{}

  defp build_methods_tbl(methods) do
    Map.new(OJ.pairs(methods), fn {name, group} ->
      cond do
        scan = OJ.get(group, "scan") ->
          {String.to_atom(name), {:scan, build_scan_def(scan)}}

        alts = OJ.get(group, "alternatives") ->
          params = Enum.map(OJ.get(group, "params") || [], &String.to_atom/1)
          {String.to_atom(name), {:alts, Enum.map(alts, &build_method_alt(params, &1))}}

        true ->
          raise "Uro.Planner.ElixirAdapter: method group #{name} has neither " <>
                  "\"alternatives\" nor \"scan\""
      end
    end)
  end

  defp build_method_alt(params, alt) do
    binds = build_binds(OJ.get(alt, "bind") || [])
    checks = build_checks(OJ.get(alt, "check") || [])
    subtasks = build_subtask_defs(OJ.get(alt, "subtasks") || [])
    {params, binds, checks, subtasks}
  end

  # --- Scan methods (Stage 5B): over/recurse/branches/done. ---

  defp build_scan_def(scan) do
    over = String.to_atom(OJ.get(scan, "over"))

    recurse =
      case OJ.get(scan, "recurse") do
        nil -> false
        name -> String.to_atom(name)
      end

    branches = Enum.map(OJ.get(scan, "branches") || [], &build_scan_branch/1)
    done_check = build_checks(OJ.get(scan, "done") || [])
    done_subtasks = build_subtask_defs(OJ.get(scan, "done_subtasks") || [])
    {over, recurse, branches, done_check, done_subtasks}
  end

  defp build_scan_branch(branch) do
    binds = build_binds(OJ.get(branch, "bind") || [])
    checks = build_checks(OJ.get(branch, "check") || [])
    subtasks = build_subtask_defs(OJ.get(branch, "subtasks") || [])
    {binds, checks, subtasks}
  end

  defp build_checks(check_clauses) do
    Enum.map(check_clauses, fn clause -> compile_node(OJ.get(clause, "eval")) end)
  end

  defp build_subtask_defs(subtask_defs) do
    Enum.map(subtask_defs, fn [name | arg_nodes] ->
      {String.to_atom(name), Enum.map(arg_nodes, &compile_node/1)}
    end)
  end

  # --- Tasks (todo_list): an array. Each item is either a plain array
  #     (a "call") or an object (a "goal"/"multigoal"). ---

  defp build_tasks(todo_list), do: Enum.map(todo_list, &compile_task/1)

  defp compile_task([name | args]) when is_binary(name),
    do: {:call, String.to_atom(name), Enum.map(args, &from_domain_value/1)}

  defp compile_task({:obj, _} = task) do
    cond do
      entries = OJ.get(task, "goal") ->
        {:goal, Enum.map(entries, &compile_goal_entry/1)}

      vars = OJ.get(task, "multigoal") ->
        # Order matters: try_multigoal_bindings tries unmet bindings in
        # this exact order, so both levels must preserve JSON key order
        # (OJ.pairs/1, not a plain-map comprehension).
        bindings =
          for {var, kv} <- OJ.pairs(vars), {key, desired} <- OJ.pairs(kv) do
            {String.to_atom(var), String.to_atom(key), from_domain_value(desired)}
          end

        {:multigoal, bindings}

      true ->
        raise "Uro.Planner.ElixirAdapter: todo_list entry #{inspect(task)} is neither " <>
                "a call, a goal, nor a multigoal"
    end
  end

  defp compile_goal_entry(entry) do
    {var, key} = parse_pointer(OJ.get(entry, "pointer"))
    {var, key, from_domain_value(OJ.get(entry, "eq"))}
  end

  # --- Node compilation: JSON KHR_interactivity-shaped values into a
  #     tagged tuple. A non-object value is a literal, except the
  #     single-param-reference shorthand "{name}". ---

  @supported_node_types ~w(eq lt add sub not and or get)

  defp compile_node({:obj, _} = node) do
    type = OJ.get(node, "type")
    short = type |> String.split("/") |> List.last()

    unless short in @supported_node_types do
      raise "Uro.Planner.ElixirAdapter: unsupported node type #{inspect(type)} " <>
              "(eq/lt/add/sub/not/and/or/get only -- no floats/trig/quaternion/matrix nodes)"
    end

    case short do
      "get" ->
        compile_get_pointer(OJ.get(node, "pointer"))

      "not" ->
        {:not, compile_node(OJ.get(node, "a"))}

      _ ->
        {String.to_atom(short), compile_node(OJ.get(node, "a")), compile_node(OJ.get(node, "b"))}
    end
  end

  defp compile_node("{" <> _ = ref) do
    case Regex.run(~r/^\{([^{}]+)\}$/, ref) do
      [_, name] -> {:param, String.to_atom(name)}
      nil -> {:lit, String.to_atom(ref)}
    end
  end

  defp compile_node(value), do: {:lit, from_domain_value(value)}

  # --- RFC 6901-ish 2-segment pointer. `bind`/`pointer/set` pointers are
  #     always fixed /var/key paths -- Stage 5B's scan branches instead
  #     make the current key available to check/subtask nodes via the
  #     ordinary "{_key}" param shorthand. A "get" node's key segment is
  #     the one narrow exception: it may be a single "{name}" template
  #     (resolved against params at eval time, e.g. "/npcs/{_key}" reads
  #     whatever state[npcs][<the current scan key>] holds) -- this is
  #     what makes a scan branch's `check` able to inspect the entity at
  #     each key, not just its key name. Still far short of native's
  #     multi-segment/multi-template RFC 6901 substitution: exactly one
  #     template, and only in the key segment. ---

  defp parse_pointer("/" <> rest) do
    case String.split(rest, "/") do
      [var, key] -> {String.to_atom(var), String.to_atom(key)}
      _ -> raise "Uro.Planner.ElixirAdapter: pointer must be exactly /var/key, got #{rest}"
    end
  end

  defp compile_get_pointer("/" <> rest) do
    case String.split(rest, "/") do
      [var, "{" <> _ = key_ref] ->
        case Regex.run(~r/^\{([^{}]+)\}$/, key_ref) do
          [_, name] -> {:get_dynamic_key, String.to_atom(var), String.to_atom(name)}
          nil -> raise "Uro.Planner.ElixirAdapter: malformed key template #{key_ref}"
        end

      [var, key] ->
        {:get, String.to_atom(var), String.to_atom(key)}

      _ ->
        raise "Uro.Planner.ElixirAdapter: pointer must be exactly /var/key, got #{rest}"
    end
  end

  # ===========================================================================
  # HTN search + domain evaluation (plain-Elixir port of planner.scm)
  # ===========================================================================

  # --- State access: a 2-level map, var -> (key -> value). Reading a
  #     var/key that was never set returns `false` (matches s7
  #     hash-table-ref's own "missing key -> #f"); writing one that
  #     doesn't exist yet creates it. ---

  defp nested_ref(state, var, key) do
    case Map.get(state, var) do
      nil -> false
      inner -> Map.get(inner, key, false)
    end
  end

  defp nested_set(state, var, key, value) do
    inner = Map.get(state, var, %{})
    Map.put(state, var, Map.put(inner, key, value))
  end

  defp binding_satisfied?(state, {var, key, desired}), do: nested_ref(state, var, key) == desired

  defp goal_satisfied_all?(state, bindings),
    do: Enum.all?(bindings, &binding_satisfied?(state, &1))

  defp first_unmet(state, bindings), do: Enum.find(bindings, &(!binding_satisfied?(state, &1)))

  defp all_unmet(state, bindings), do: Enum.reject(bindings, &binding_satisfied?(state, &1))

  # --- params: name -> value, built from positional args then widened
  #     by binds (nested-refs against state). ---

  defp build_params(names, args), do: Enum.zip(names, args) |> Map.new()

  defp run_binds(params, binds, state) do
    Enum.reduce(binds, params, fn {name, var, key}, params ->
      Map.put(params, name, nested_ref(state, var, key))
    end)
  end

  # --- Expression evaluator: the KHR_interactivity-style node language,
  #     restricted to what this stage needs. Scheme truthiness carried
  #     over: only `false` is false, so :and/:or return the last
  #     evaluated operand's actual value, not a coerced boolean. ---

  defp eval_node({:lit, v}, _params, _state), do: v
  defp eval_node({:param, name}, params, _state), do: Map.get(params, name, false)
  defp eval_node({:get, var, key}, _params, state), do: nested_ref(state, var, key)

  defp eval_node({:get_dynamic_key, var, key_param}, params, state),
    do: nested_ref(state, var, Map.get(params, key_param, false))

  defp eval_node({:eq, a, b}, params, state),
    do: eval_node(a, params, state) == eval_node(b, params, state)

  defp eval_node({:lt, a, b}, params, state),
    do: eval_node(a, params, state) < eval_node(b, params, state)

  defp eval_node({:add, a, b}, params, state),
    do: eval_node(a, params, state) + eval_node(b, params, state)

  defp eval_node({:sub, a, b}, params, state),
    do: eval_node(a, params, state) - eval_node(b, params, state)

  defp eval_node({:not, a}, params, state), do: eval_node(a, params, state) == false

  defp eval_node({:and, a, b}, params, state) do
    case eval_node(a, params, state) do
      false -> false
      _ -> eval_node(b, params, state)
    end
  end

  defp eval_node({:or, a, b}, params, state) do
    case eval_node(a, params, state) do
      false -> eval_node(b, params, state)
      other -> other
    end
  end

  defp eval_node_list(nodes, params, state), do: Enum.map(nodes, &eval_node(&1, params, state))

  # --- Actions: {params, binds, body} -> a new state, or `false` if a
  #     body "eval" step fails. ---

  defp apply_action({param_names, binds, body}, state, args) do
    params = build_params(param_names, args) |> run_binds(binds, state)
    run_body(body, params, state)
  end

  defp run_body([], _params, state), do: state

  defp run_body([{:eval, node} | rest], params, state) do
    if eval_node(node, params, state) != false do
      run_body(rest, params, state)
    else
      false
    end
  end

  defp run_body([{:set, var, key, node} | rest], params, state) do
    run_body(rest, params, nested_set(state, var, key, eval_node(node, params, state)))
  end

  # --- Methods: {params, binds, checks, subtasks} -> a (possibly empty)
  #     subtask list, or `false` if a check clause fails. ---

  defp run_checks(checks, params, state),
    do: Enum.all?(checks, &(eval_node(&1, params, state) != false))

  defp build_subtasks(defs, params, state) do
    Enum.map(defs, fn {name, arg_nodes} ->
      {:call, name, eval_node_list(arg_nodes, params, state)}
    end)
  end

  defp try_method({params, binds, checks, subtask_defs}, state, args) do
    params = build_params(params, args) |> run_binds(binds, state)

    if run_checks(checks, params, state) do
      build_subtasks(subtask_defs, params, state)
    else
      false
    end
  end

  # --- Scan methods (Stage 5B): try every branch in order; within a
  #     branch, try every key of state[over] before moving to the next
  #     branch. First (branch, key) whose binds+checks succeed wins.
  #     One key-list-ordering divergence from native, documented rather
  #     than silently assumed: `Map.keys/1` returns whatever order the
  #     map happens to store its keys in, not insertion order like
  #     native's tsl::ordered_map -- matters only when more than one key
  #     would satisfy the same branch, in which case native and this
  #     port may pick a different (still valid) one. ---

  defp try_scan_method(state, {over, recurse, branches, done_check, done_subtasks}, _ctx) do
    keys = state |> Map.get(over, %{}) |> Map.keys()

    case try_scan_branches(state, branches, keys) do
      false ->
        if run_checks(done_check, %{}, state) do
          build_subtasks(done_subtasks, %{}, state)
        else
          false
        end

      subtasks ->
        case recurse do
          false -> subtasks
          name -> subtasks ++ [{:call, name, []}]
        end
    end
  end

  defp try_scan_branches(_state, [], _keys), do: false

  defp try_scan_branches(state, [branch | rest], keys) do
    case try_scan_branch_keys(state, branch, keys) do
      false -> try_scan_branches(state, rest, keys)
      subtasks -> subtasks
    end
  end

  defp try_scan_branch_keys(_state, _branch, []), do: false

  defp try_scan_branch_keys(state, {binds, checks, subtask_defs} = branch, [key | rest]) do
    params = %{@scan_key_name => key} |> run_binds(binds, state)

    if run_checks(checks, params, state) do
      build_subtasks(subtask_defs, params, state)
    else
      try_scan_branch_keys(state, branch, rest)
    end
  end

  # --- The walker: advances through satisfied goals/primitive actions
  #     without spending fuel, recursing into a fuel-spending branch
  #     function only once a real decision is needed. Returns a plan
  #     (list of executed {:call, name, args} tasks) or `false`. `[]`
  #     (the empty plan) is a legitimate SUCCESS, not falsy -- only
  #     `false` is false here, matching planner.scm's Scheme
  #     truthiness, so every `case` below distinguishes "found the
  #     empty plan" from "failed" correctly. ---

  defp walk_tasks(_state, [], _fuel, _ctx), do: []

  defp walk_tasks(state, [task | rest] = tasks, fuel, ctx) do
    case task do
      {:goal, bindings} ->
        if goal_satisfied_all?(state, bindings) do
          walk_tasks(state, rest, fuel, ctx)
        else
          branch_goal(state, tasks, fuel, ctx)
        end

      {:multigoal, bindings} ->
        if goal_satisfied_all?(state, bindings) do
          walk_tasks(state, rest, fuel, ctx)
        else
          branch_multigoal(state, tasks, fuel, ctx)
        end

      {:call, _name, _args} ->
        walk_call(state, tasks, fuel, ctx)
    end
  end

  defp walk_call(state, [task | rest], fuel, ctx) do
    {:call, name, args} = task

    case Map.fetch(ctx.actions, name) do
      {:ok, action} ->
        case apply_action(action, state, args) do
          false ->
            false

          new_state ->
            case walk_tasks(new_state, rest, fuel, ctx) do
              false -> false
              plan_rest -> [task | plan_rest]
            end
        end

      :error ->
        branch_compound(state, [task | rest], fuel, ctx)
    end
  end

  # --- Branching: unmet TwGoal -- pick the first unmet binding, dispatch
  #     to whatever's registered under its var name (an alternatives
  #     list or a scan method). `splice` re-appends the goal itself so
  #     it re-verifies before `remaining` runs -- the one difference
  #     from the compound case below. ---

  defp branch_goal(_state, _tasks, fuel, _ctx) when fuel < 1, do: false

  defp branch_goal(state, [goal | remaining], fuel, ctx) do
    {:goal, bindings} = goal
    {var, key, desired} = first_unmet(state, bindings)
    splice = fn subtasks -> subtasks ++ [goal | remaining] end
    dispatch_methods(state, Map.fetch(ctx.methods, var), [key, desired], splice, fuel - 1, ctx)
  end

  # --- Branching: TwMultiGoal -- try EVERY unmet binding as the next
  #     thing to satisfy (real backtracking over binding choice). ---

  defp branch_multigoal(_state, _tasks, fuel, _ctx) when fuel < 1, do: false

  defp branch_multigoal(state, [mg | remaining], fuel, ctx) do
    {:multigoal, bindings} = mg
    unmet_list = all_unmet(state, bindings)
    try_multigoal_bindings(state, unmet_list, mg, remaining, fuel - 1, ctx)
  end

  defp try_multigoal_bindings(_state, [], _mg, _remaining, _fuel, _ctx), do: false

  defp try_multigoal_bindings(state, [binding | rest], mg, remaining, fuel, ctx) do
    sub_goal = {:goal, [binding]}

    case walk_tasks(state, [sub_goal, mg | remaining], fuel, ctx) do
      false -> try_multigoal_bindings(state, rest, mg, remaining, fuel, ctx)
      result -> result
    end
  end

  # --- Branching: compound TwCall -- dispatch to whatever's registered
  #     under the task's own name. No self-re-append (unlike the goal
  #     case): `splice` drops the task and keeps only `remaining`. ---

  defp branch_compound(_state, _tasks, fuel, _ctx) when fuel < 1, do: false

  defp branch_compound(state, [task | remaining], fuel, ctx) do
    {:call, name, args} = task
    splice = fn subtasks -> subtasks ++ remaining end
    dispatch_methods(state, Map.fetch(ctx.methods, name), args, splice, fuel - 1, ctx)
  end

  # --- Shared by branch_goal/branch_compound: a methods-tbl entry is
  #     either a scan method (run once, no alternatives to fall back
  #     to) or a list of alternatives (tried in order until one's
  #     subtasks lead to a full plan). `splice` is how the caller wants
  #     the winning subtasks folded back into the task list. ---

  defp dispatch_methods(_state, :error, _args, _splice, _fuel, _ctx), do: false

  defp dispatch_methods(state, {:ok, {:scan, scan_def}}, _args, splice, fuel, ctx) do
    case try_scan_method(state, scan_def, ctx) do
      false -> false
      subtasks -> walk_tasks(state, splice.(subtasks), fuel, ctx)
    end
  end

  defp dispatch_methods(state, {:ok, {:alts, methods}}, args, splice, fuel, ctx),
    do: try_alternatives(state, methods, args, splice, fuel, ctx)

  defp try_alternatives(_state, [], _args, _splice, _fuel, _ctx), do: false

  defp try_alternatives(state, [method | rest], args, splice, fuel, ctx) do
    case try_method(method, state, args) do
      false ->
        try_alternatives(state, rest, args, splice, fuel, ctx)

      subtasks ->
        case walk_tasks(state, splice.(subtasks), fuel, ctx) do
          false -> try_alternatives(state, rest, args, splice, fuel, ctx)
          result -> result
        end
    end
  end
end

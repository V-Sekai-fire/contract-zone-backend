# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.MCExecutor do
  @moduledoc """
  Hand-ported from `standalone/tw_mc_executor.hpp` into plain Elixir --
  same reasoning as `Uro.Planner.Replan` (RFD66606-0030): domain actions are
  an injected `%{name => (state, args -> state | nil)}` map (matching
  `Replan`'s own `action_fn` contract) rather than re-deriving domain
  loading, since that's `Uro.Planner.ElixirAdapter`'s job, not this
  module's.

  Unlike the original, this module does NOT round-trip state through
  JSON strings -- state is a plain map throughout, and each step's
  post-state is returned as that map directly (`nil` when the step
  didn't succeed), since nothing here crosses a language boundary.

  The RNG is Erlang's built-in `:rand` (`exsss` algorithm), not a
  hand-rolled `std::mt19937_64` -- this module is a stochastic
  what-if simulator, not verified game logic, so bit-identical draws
  against the C++ oracle are not a goal (the C++ port itself already
  diverges from the upstream Python `mc_executor.py`'s Mersenne
  Twister draws, since `std::mt19937_64` and CPython's 32-bit
  `random` are different generators). Determinism *within* Elixir
  (same seed -> same sequence) is what callers actually need, and
  `:rand.seed_s/2` + `:rand.uniform_s/1` provide exactly that.
  """

  @type call :: {String.t(), [term()]}
  @type action_fn :: (map(), [term()] -> map() | nil)
  @type actions :: %{String.t() => action_fn()}

  @type step :: %{action: call(), succeeded: boolean(), state: map() | nil}

  @doc """
  Executes `plan` against `init_state`, drawing one uniform(0,1) sample
  per step and comparing against that step's success probability
  (`probs` at the same index, default `1.0`). A step "succeeds" when
  the draw is below its probability AND (if the action name is known)
  applying it doesn't return `nil`. Stops at the first failed step.

  Mirrors the original's one quirk exactly: if the drawn outcome is a
  success but the action name isn't in `actions`, the step is still
  recorded as succeeded with the state left unchanged (the C++ code
  has no `else` branch on a failed lookup).

  `opts`: `:probs` (default `[]`, meaning every step defaults to 1.0),
  `:seed` (default `10`, matching the Python original's default),
  `:actions` (required).
  """
  @spec execute(map(), [call()], keyword()) :: %{
          steps: [step()],
          completed: non_neg_integer(),
          failed_at: non_neg_integer() | nil
        }
  def execute(init_state, plan, opts) do
    probs = Keyword.get(opts, :probs, [])
    seed = Keyword.get(opts, :seed, 10)
    actions = Keyword.fetch!(opts, :actions)

    rand_state = :rand.seed_s(:exsss, {seed, seed, seed})

    plan
    |> Enum.with_index()
    |> Enum.reduce_while({[], init_state, rand_state, 0}, fn {{name, args} = call, i},
                                                             {steps, state, rstate, completed} ->
      prob = Enum.at(probs, i, 1.0)
      {draw, rstate2} = :rand.uniform_s(rstate)
      drawn_success = draw < prob

      {succeeded, next_state} =
        if drawn_success do
          case Map.fetch(actions, name) do
            {:ok, action_fn} ->
              case action_fn.(state, args) do
                nil -> {false, state}
                new_state -> {true, new_state}
              end

            :error ->
              {true, state}
          end
        else
          {false, state}
        end

      step = %{
        action: call,
        succeeded: succeeded,
        state: if(succeeded, do: next_state, else: nil)
      }

      acc = {[step | steps], next_state, rstate2, completed}

      if succeeded do
        {:cont, put_elem(acc, 3, completed + 1)}
      else
        {:halt, {[step | steps], next_state, rstate2, completed, i}}
      end
    end)
    |> finalize()
  end

  defp finalize({steps, _state, _rstate, completed}) do
    %{steps: Enum.reverse(steps), completed: completed, failed_at: nil}
  end

  defp finalize({steps, _state, _rstate, completed, failed_at}) do
    %{steps: Enum.reverse(steps), completed: completed, failed_at: failed_at}
  end
end

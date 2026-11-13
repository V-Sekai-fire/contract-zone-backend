# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.TuplesPropertyTest do
  @moduledoc """
  Random sequences of put, delete and replace against `Uro.Tuples`, compared after every
  step with a plain model.

  The model is a map from each stored (subject, verb, object) to its epoch: its keys are
  the set of tuples and its values are the epochs. A put adds the tuple at epoch 0 unless
  it is there; a delete removes it; a replace removes every tuple with that verb and
  object and adds the new subject's tuple at one more than the highest epoch the object
  had. After each step the rows of the table must be the model, and `epoch/1` of each
  object must be the highest epoch in the model for it.

  PropCheck is not a dependency of this project, so the sequences come from `:rand` with a
  seed that is printed when a sequence fails. There is no shrinking. The pools are small
  so that puts repeat, deletes hit, and replaces find several holders.
  """
  use Uro.RepoCase, async: false

  alias Uro.Tuples
  alias Uro.Tuples.Tuple

  @runs 300
  @max_steps 30
  @subjects ~w(alice bob carol)
  @verbs ~w(CONTROLS SEES)
  @objects ~w(ball-7 ball-8)

  test "after any puts, deletes and replaces the table is the model" do
    seed = :rand.uniform(4_294_967_296)
    state = :rand.seed_s(:exsss, seed)

    {_state, {replaces, removed}} =
      Enum.reduce(1..@runs, {state, {0, 0}}, fn run, {state, counts} ->
        Repo.delete_all(Tuple)
        {steps, state} = gen_steps(state)

        {_model, counts} =
          Enum.reduce(steps, {%{}, counts}, fn step, {model, {replaces, removed}} ->
            context = "seed #{seed}, run #{run}, step #{inspect(step)}, before #{inspect(model)}"
            expected = model_step(step, model)
            apply_step(step, context)

            assert stored() == expected, "the table is not the model (#{context})"

            for object <- @objects do
              assert Tuples.epoch(object) == model_epoch(expected, object),
                     "the epoch of #{object} is wrong (#{context})"
            end

            case step do
              {:replace, _, _, _} ->
                {expected, {replaces + 1, removed + map_size(model) + 1 - map_size(expected)}}

              _ ->
                {expected, {replaces, removed}}
            end
          end)

        {state, counts}
      end)

    assert replaces > 0, "no sequence had a replace (seed #{seed})"
    assert removed > 0, "no replace removed a holder (seed #{seed})"
  end

  defp gen_steps(state) do
    {n, state} = :rand.uniform_s(@max_steps, state)

    Enum.map_reduce(1..n, state, fn _, state ->
      {kind, state} = :rand.uniform_s(5, state)
      {subject, state} = pick(@subjects, state)
      {verb, state} = pick(@verbs, state)
      {object, state} = pick(@objects, state)

      {{Enum.at([:put, :put, :delete, :replace, :replace], kind - 1), subject, verb, object},
       state}
    end)
  end

  defp pick(pool, state) do
    {n, state} = :rand.uniform_s(length(pool), state)
    {Enum.at(pool, n - 1), state}
  end

  defp apply_step({:put, s, v, o}, context) do
    assert {:ok, %Tuple{subject: ^s, verb: ^v, object: ^o}} = Tuples.put(s, v, o), context
  end

  defp apply_step({:delete, s, v, o}, context) do
    assert {:ok, n} = Tuples.delete(s, v, o), context
    assert n in [0, 1], context
  end

  defp apply_step({:replace, s, v, o}, context) do
    assert {:ok, %Tuple{subject: ^s, verb: ^v, object: ^o}} = Tuples.replace(v, o, s), context
  end

  defp model_step({:put, s, v, o}, model), do: Map.put_new(model, {s, v, o}, 0)
  defp model_step({:delete, s, v, o}, model), do: Map.delete(model, {s, v, o})

  defp model_step({:replace, s, v, o}, model) do
    model
    |> Map.reject(fn {{_s, verb, object}, _epoch} -> verb == v and object == o end)
    |> Map.put({s, v, o}, model_epoch(model, o) + 1)
  end

  defp model_epoch(model, object) do
    Enum.max(for({{_s, _v, ^object}, epoch} <- model, do: epoch), fn -> 0 end)
  end

  defp stored do
    Map.new(Repo.all(Tuple), fn t -> {{t.subject, t.verb, t.object}, t.epoch} end)
  end
end

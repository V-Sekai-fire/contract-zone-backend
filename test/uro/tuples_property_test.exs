# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.TuplesPropertyTest do
  @moduledoc """
  Random sequences of put, delete and replace against `Uro.Tuples`, compared after every
  step with a plain model.

  The model has two parts. The first is a map from each stored (subject, verb, object) to
  the epoch of its row: a put adds the tuple at epoch 0 unless it is there; a delete
  removes it; a replace removes every tuple with that verb and object and adds the new
  subject's tuple at the object's new epoch. The second is a map from each object to its
  epoch, which only a replace changes, by one. No delete takes anything out of it: it is
  kept when a sequence deletes every tuple of an object, and also from one run to the
  next, where the test deletes all tuples but leaves the epoch rows. After each step the
  rows of the table must be the first part, `epoch/1` of each object must be the second,
  and an epoch that a replace gives must be one the object never had.

  The test fails if no replace came after an object had lost every tuple, because that is
  the case the epoch rows are for.

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

    {_state, _epochs, {replaces, removed, after_empty}} =
      Enum.reduce(1..@runs, {state, %{}, {0, 0, 0}}, fn run, {state, epochs, counts} ->
        Repo.delete_all(Tuple)
        {steps, state} = gen_steps(state)

        {{_tuples, epochs}, counts} =
          Enum.reduce(steps, {{%{}, epochs}, counts}, fn step, {model, counts} ->
            context = "seed #{seed}, run #{run}, step #{inspect(step)}, before #{inspect(model)}"
            {tuples, epochs} = expected = model_step(step, model)
            apply_step(step, context)

            assert stored() == tuples, "the table is not the model (#{context})"

            for object <- @objects do
              assert Tuples.epoch(object) == Map.get(epochs, object, 0),
                     "the epoch of #{object} is wrong (#{context})"
            end

            {expected, count(step, model, expected, counts)}
          end)

        {state, epochs, counts}
      end)

    assert replaces > 0, "no sequence had a replace (seed #{seed})"
    assert removed > 0, "no replace removed a holder (seed #{seed})"
    assert after_empty > 0, "no replace came after an object lost every tuple (seed #{seed})"
  end

  defp count({:replace, _s, _v, o}, {before, epochs}, {tuples, _}, {replaces, removed, empty}) do
    bare = if is_map_key(epochs, o) and not has_object?(before, o), do: 1, else: 0
    {replaces + 1, removed + map_size(before) + 1 - map_size(tuples), empty + bare}
  end

  defp count(_step, _before, _expected, counts), do: counts

  defp has_object?(tuples, object), do: Enum.any?(tuples, fn {{_s, _v, o}, _} -> o == object end)

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

  defp model_step({:put, s, v, o}, {tuples, epochs}) do
    {Map.put_new(tuples, {s, v, o}, 0), epochs}
  end

  defp model_step({:delete, s, v, o}, {tuples, epochs}) do
    {Map.delete(tuples, {s, v, o}), epochs}
  end

  defp model_step({:replace, s, v, o}, {tuples, epochs}) do
    epoch = Map.get(epochs, o, 0) + 1

    tuples =
      tuples
      |> Map.reject(fn {{_s, verb, object}, _epoch} -> verb == v and object == o end)
      |> Map.put({s, v, o}, epoch)

    {tuples, Map.put(epochs, o, epoch)}
  end

  defp stored do
    Map.new(Repo.all(Tuple), fn t -> {{t.subject, t.verb, t.object}, t.epoch} end)
  end
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Tuples do
  @moduledoc """
  Stored relationship tuples.

  A tuple says that `subject` has the relation `verb` to `object`, for example
  "alice" "CONTROLS" "ball-7". The rows are in the `tuples` table, one row for each
  (subject, verb, object). A verb may be given as a string or as an atom; an atom is
  stored as its string, so `:OWNS` and `"OWNS"` are the same verb. These are the relation
  names `Uro.Ports.ReBAC` uses.

  An empty subject, verb or object is refused with `{:error, changeset}`.
  """

  import Ecto.Query

  alias Uro.Repo
  alias Uro.Tuples.Tuple

  @type verb :: String.t() | atom()

  @doc """
  Stores the tuple. Putting a tuple that is already stored changes nothing and returns
  the stored row, so a tuple may be granted any number of times.
  """
  @spec put(String.t(), verb(), String.t()) :: {:ok, Tuple.t()} | {:error, Ecto.Changeset.t()}
  def put(subject, verb, object) do
    attrs = %{subject: subject, verb: verb_string(verb), object: object}
    changeset = Tuple.changeset(%Tuple{}, attrs)

    with {:ok, _} <-
           Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:subject, :verb, :object]
           ) do
      {:ok, Repo.one!(where(Tuple, ^Keyword.new(changeset.changes)))}
    end
  end

  @doc "Removes the tuple and returns how many rows went: 1, or 0 if it was not stored."
  @spec delete(String.t(), verb(), String.t()) :: {:ok, non_neg_integer()}
  def delete(subject, verb, object) do
    {count, _} = Repo.delete_all(one(subject, verb, object))
    {:ok, count}
  end

  @spec has?(String.t(), verb(), String.t()) :: boolean()
  def has?(subject, verb, object), do: Repo.exists?(one(subject, verb, object))

  @doc "Every tuple whose object is `object`."
  @spec list_for_object(String.t()) :: [Tuple.t()]
  def list_for_object(object) do
    Repo.all(from t in Tuple, where: t.object == ^object, order_by: [t.verb, t.subject])
  end

  defp one(subject, verb, object) do
    verb = verb_string(verb)
    from t in Tuple, where: t.subject == ^subject and t.verb == ^verb and t.object == ^object
  end

  defp verb_string(nil), do: nil
  defp verb_string(verb) when is_atom(verb), do: Atom.to_string(verb)
  defp verb_string(verb), do: verb
end

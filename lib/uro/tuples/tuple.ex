# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Tuples.Tuple do
  @moduledoc """
  One relationship tuple: `subject` has the relation `verb` to `object`.

  The three are strings and none may be empty. `epoch` is the epoch the object had when
  the row was stored by `Uro.Tuples.replace/3`; a tuple that was only put has epoch 0. The
  epoch of the object itself is in `Uro.Tuples.Epoch`, not here. The table has one row for
  each (subject, verb, object).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "tuples" do
    field :subject, :string
    field :verb, :string
    field :object, :string
    field :epoch, :integer, default: 0

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tuple, attrs) do
    tuple
    |> cast(attrs, [:subject, :verb, :object, :epoch])
    |> validate_required([:subject, :verb, :object])
    |> validate_number(:epoch, greater_than_or_equal_to: 0)
    |> unique_constraint([:subject, :verb, :object])
  end
end

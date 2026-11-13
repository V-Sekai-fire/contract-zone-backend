# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Tuples.Epoch do
  @moduledoc """
  The epoch of one object: how many times `Uro.Tuples.replace/3` has handed it over.

  The table `tuple_epochs` has at most one row for each object, with the object as its
  key. An object without a row has epoch 0. `Uro.Tuples.replace/3` is the only writer: it
  makes the row at 1 or adds 1 to it. Nothing lowers a row and nothing deletes one, so
  the rows outlive the tuples of their objects.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:object, :string, autogenerate: false}
  schema "tuple_epochs" do
    field :epoch, :integer, default: 0
  end
end

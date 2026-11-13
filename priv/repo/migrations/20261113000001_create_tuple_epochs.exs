# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Repo.Migrations.CreateTupleEpochs do
  @moduledoc """
  Gives each object its own epoch row, so that an epoch outlives the object's tuples.

  `up/0` creates `tuple_epochs` (object as the key, epoch) and gives each object that has
  tuples with an epoch above 0 a row with the highest of them, which is what
  `Uro.Tuples.epoch/1` returned for it before. An object whose rows are all at 0 gets no
  row, because no row means 0. The `epoch` column of `tuples` stays: a row keeps the epoch
  at which it was stored.

  `down/0` drops the table. The epochs on the tuple rows are still there, so what is lost
  is the epoch of each object that has no tuple left.
  """
  use Ecto.Migration

  def up do
    create table(:tuple_epochs, primary_key: false) do
      add(:object, :string, primary_key: true)
      add(:epoch, :integer, null: false, default: 0)
    end

    flush()

    execute("""
    INSERT INTO tuple_epochs (object, epoch)
    SELECT object, MAX(epoch) FROM tuples GROUP BY object HAVING MAX(epoch) > 0
    """)
  end

  def down do
    drop(table(:tuple_epochs))
  end
end

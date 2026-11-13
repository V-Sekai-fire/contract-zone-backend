# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Repo.Migrations.CreateTuples do
  use Ecto.Migration

  def up do
    create table(:tuples) do
      add(:subject, :string, null: false)
      add(:verb, :string, null: false)
      add(:object, :string, null: false)
      add(:epoch, :integer, null: false, default: 0)

      timestamps()
    end

    create(unique_index(:tuples, [:subject, :verb, :object]))
    create(index(:tuples, [:object]))
  end

  def down do
    drop(table(:tuples))
  end
end

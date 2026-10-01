# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Repo.Migrations.AddBakeFieldsToSharedFiles do
  use Ecto.Migration

  def change do
    alter table(:shared_files) do
      add :store_url, :string, null: true
      add :chunks, :map, null: true
      add :baked_url, :string, null: true
    end
  end
end

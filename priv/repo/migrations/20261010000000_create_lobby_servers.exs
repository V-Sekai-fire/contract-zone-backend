# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Repo.Migrations.CreateLobbyServers do
  use Ecto.Migration

  def up do
    create table(:lobby_servers, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:platform, :string, null: false)
      add(:external_id, :string, null: false)
      add(:address, :string, null: false)
      add(:name, :string, null: false)
      add(:motd, :string)
      add(:online, :integer)
      add(:capacity, :integer)
      add(:status, :string, null: false, default: "unknown")
      add(:client_url, :string)
      add(:last_polled_at, :utc_datetime)
      add(:last_seen_at, :utc_datetime)

      timestamps(inserted_at: :created_at)
    end

    create(unique_index(:lobby_servers, [:platform, :external_id]))
  end

  def down do
    drop(table(:lobby_servers))
  end
end

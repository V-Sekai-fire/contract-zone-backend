# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Repo.Migrations.CreateSecondFactors do
  use Ecto.Migration

  def change do
    create table(:user_totp, primary_key: false) do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:sealed_secret, :text, null: false)
      add(:last_step, :bigint, null: false, default: 0)
      add(:enabled_at, :utc_datetime, null: false)
    end

    create table(:user_totp_enrollments, primary_key: false) do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:sealed_secret, :text, null: false)
      add(:created_at, :utc_datetime, null: false)
    end

    create table(:user_backup_codes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:code_hash, :binary, null: false)
      add(:created_at, :utc_datetime, null: false)
    end

    create(unique_index(:user_backup_codes, [:user_id, :code_hash]))
  end
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Repo.Migrations.CreatePasskeys do
  use Ecto.Migration

  def change do
    create table(:user_passkeys, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:credential_id, :binary, null: false)
      add(:cose_key, :binary, null: false)
      add(:sign_count, :bigint, null: false, default: 0)
      add(:created_at, :utc_datetime, null: false)
    end

    create(unique_index(:user_passkeys, [:credential_id]))
    create(index(:user_passkeys, [:user_id]))

    create table(:passkey_registration_challenges, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:challenge, :binary, null: false)
      add(:created_at, :utc_datetime, null: false)
    end

    create table(:passkey_login_challenges, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:challenge, :binary, null: false)
      add(:created_at, :utc_datetime, null: false)
    end
  end
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Repo.Migrations.CreateDeviceAuthorizations do
  use Ecto.Migration

  def change do
    create table(:device_authorizations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:device_code_hash, :binary, null: false)
      add(:user_code, :string, null: false)
      add(:client_id, :string, null: false)
      add(:interval_s, :integer, null: false)
      add(:expires_at, :utc_datetime, null: false)
      add(:created_at, :utc_datetime, null: false)
    end

    create(unique_index(:device_authorizations, [:device_code_hash]))
    create(unique_index(:device_authorizations, [:user_code]))

    create table(:device_authorization_polls, primary_key: false) do
      add(
        :authorization_id,
        references(:device_authorizations, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:polled_at, :utc_datetime, null: false)
    end

    create table(:device_authorization_approvals, primary_key: false) do
      add(
        :authorization_id,
        references(:device_authorizations, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:approved_at, :utc_datetime, null: false)
    end

    create table(:device_authorization_denials, primary_key: false) do
      add(
        :authorization_id,
        references(:device_authorizations, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:denied_at, :utc_datetime, null: false)
    end
  end
end

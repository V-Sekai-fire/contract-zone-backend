# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.SecondFactor.BackupCode do
  @moduledoc "One unused backup code, kept only as its keyed hash; using it deletes the row."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "user_backup_codes" do
    field(:user_id, :binary_id)
    field(:code_hash, :binary)
    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end

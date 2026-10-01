# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Passkeys.Passkey do
  @moduledoc "A WebAuthn credential a user registered: its id, public COSE key and signature count."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_passkeys" do
    belongs_to(:user, Uro.Accounts.User)
    field(:credential_id, :binary)
    field(:cose_key, :binary)
    field(:sign_count, :integer, default: 0)
    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end

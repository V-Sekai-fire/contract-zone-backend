# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Passkeys.RegistrationChallenge do
  @moduledoc "A WebAuthn registration challenge issued to a signed-in user, spent on first use."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "passkey_registration_challenges" do
    field(:user_id, :binary_id)
    field(:challenge, :binary)
    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end

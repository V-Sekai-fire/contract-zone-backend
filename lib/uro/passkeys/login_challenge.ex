# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Passkeys.LoginChallenge do
  @moduledoc "A WebAuthn sign-in challenge, issued to anyone and spent on first use."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "passkey_login_challenges" do
    field(:challenge, :binary)
    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.SecondFactor.TotpCredential do
  @moduledoc "A user's confirmed authenticator secret, sealed, and the last step it accepted."

  use Ecto.Schema

  @primary_key {:user_id, :binary_id, autogenerate: false}
  schema "user_totp" do
    field(:sealed_secret, :string)
    field(:last_step, :integer, default: 0)
    timestamps(type: :utc_datetime, inserted_at: :enabled_at, updated_at: false)
  end
end

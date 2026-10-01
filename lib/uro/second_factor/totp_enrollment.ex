# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.SecondFactor.TotpEnrollment do
  @moduledoc "An authenticator secret shown to a user and not yet confirmed with a code."

  use Ecto.Schema

  @primary_key {:user_id, :binary_id, autogenerate: false}
  schema "user_totp_enrollments" do
    field(:sealed_secret, :string)
    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end

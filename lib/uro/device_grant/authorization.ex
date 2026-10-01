# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.DeviceGrant.Authorization do
  @moduledoc "One RFC 8628 device authorization: the hashed device code and the code to type."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "device_authorizations" do
    field(:device_code_hash, :binary)
    field(:user_code, :string)
    field(:client_id, :string)
    field(:interval_s, :integer)
    field(:expires_at, :utc_datetime)
    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end

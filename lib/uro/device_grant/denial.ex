# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.DeviceGrant.Denial do
  @moduledoc "A signed-in user's refusal of a device authorization."

  use Ecto.Schema

  @primary_key {:authorization_id, :binary_id, autogenerate: false}
  schema "device_authorization_denials" do
    field(:denied_at, :utc_datetime)
  end
end

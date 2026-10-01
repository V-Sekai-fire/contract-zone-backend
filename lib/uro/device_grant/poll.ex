# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.DeviceGrant.Poll do
  @moduledoc "When a device last polled for its token, which paces it."

  use Ecto.Schema

  @primary_key {:authorization_id, :binary_id, autogenerate: false}
  schema "device_authorization_polls" do
    field(:polled_at, :utc_datetime)
  end
end

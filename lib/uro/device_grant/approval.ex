# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.DeviceGrant.Approval do
  @moduledoc "A signed-in user's approval of a device authorization."

  use Ecto.Schema

  @primary_key {:authorization_id, :binary_id, autogenerate: false}
  schema "device_authorization_approvals" do
    field(:user_id, :binary_id)
    field(:approved_at, :utc_datetime)
  end
end

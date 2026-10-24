# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Ports.Planner do
  @moduledoc """
  Output port for entity/behavior planning.

  Default adapter: `Uro.Planner.ElixirAdapter` (plain Elixir, RFD66606-0039).
  Tests can inject a Mox mock via
  `Application.put_env(:uro, :planner_adapter, Uro.PlannerMock)`.
  """

  @callback plan(domain_json :: String.t()) :: term()
end

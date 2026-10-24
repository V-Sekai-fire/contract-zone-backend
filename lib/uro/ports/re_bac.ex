# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Ports.ReBAC do
  @moduledoc """
  Output port for relationship-based access control checks.

  Implement this behaviour in an adapter to supply a ReBAC engine. The
  default adapter is `Uro.ReBAC.ElixirAdapter` (plain Elixir, RFD66606-0039).
  Tests can inject a Mox mock via
  `Application.put_env(:uro, :rebac_adapter, Uro.ReBACMock)`.
  """

  @type graph :: term()

  @callback new_graph() :: graph()
  @callback add_edge(graph(), subj :: String.t(), obj :: String.t(), rel :: String.t()) ::
              graph()
  @callback check_rel(graph(), subj :: String.t(), rel :: String.t(), obj :: String.t()) ::
              boolean()
end

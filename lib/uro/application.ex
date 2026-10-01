# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    # Attach OpenTelemetry instrumentation to Phoenix + Ecto. Span exporting
    # is configured via :opentelemetry / :opentelemetry_exporter in
    # config/prod.exs.
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:uro, :repo])

    children =
      if System.get_env("MINIMAL_START") == "true",
        do: [],
        else: [
          Uro.Repo,
          Uro.Endpoint,
          Uro.VSekai.ZoneJanitor,
          Uro.AgentTasks.Janitor,
          Uro.Pow.DetsCache,
          {Phoenix.PubSub, [name: Uro.PubSub, adapter: Phoenix.PubSub.PG2]},
          ExMarcel.TableWrapper,

          # ExMarcel
          {Task, fn -> Uro.Helpers.Validation.init_extra_extensions() end}
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Uro.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    Uro.Endpoint.config_change(changed, removed)
    :ok
  end
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.LobbyController do
  @moduledoc "The OMI lobby's server list, for the frontend's web root."
  use Uro, :controller

  alias OpenApiSpex.Schema
  alias Uro.Lobby

  tags(["lobby"])

  @server %Schema{
    title: "LobbyServer",
    type: :object,
    required: [:platform, :address, :name, :status],
    properties: %{
      platform: %Schema{type: :string, enum: ["basis", "overte"]},
      address: %Schema{type: :string, description: "host:port"},
      name: %Schema{type: :string},
      motd: %Schema{type: :string, nullable: true},
      online: %Schema{type: :integer, nullable: true},
      capacity: %Schema{type: :integer, nullable: true},
      status: %Schema{type: :string, enum: ["unknown", "up", "down"]},
      client_url: %Schema{type: :string, nullable: true},
      last_polled_at: %Schema{type: :string, format: :"date-time", nullable: true},
      last_seen_at: %Schema{type: :string, format: :"date-time", nullable: true}
    }
  }

  operation(:servers,
    operation_id: "lobbyServers",
    summary: "Listed Basis servers and Overte domains with their last polled health",
    responses: [
      ok: {
        "",
        "application/json",
        %Schema{
          title: "LobbyServers",
          type: :object,
          required: [:servers, :poll_interval_s, :polled_at, :next_poll_at],
          properties: %{
            servers: %Schema{type: :array, items: @server},
            poll_interval_s: %Schema{type: :integer},
            polled_at: %Schema{type: :string, format: :"date-time", nullable: true},
            next_poll_at: %Schema{type: :string, format: :"date-time", nullable: true}
          }
        }
      }
    ]
  )

  def servers(conn, _params) do
    interval_s = div(Uro.Lobby.Poller.interval_ms(), 1000)
    polled_at = Lobby.last_poll()

    json(conn, %{
      servers: Enum.map(Lobby.list_servers(), &to_json/1),
      poll_interval_s: interval_s,
      polled_at: polled_at,
      next_poll_at: polled_at && DateTime.add(polled_at, interval_s, :second)
    })
  end

  defp to_json(s) do
    Map.take(s, [
      :platform,
      :address,
      :name,
      :motd,
      :online,
      :capacity,
      :status,
      :client_url,
      :last_polled_at,
      :last_seen_at
    ])
  end
end

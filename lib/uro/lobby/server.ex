# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Lobby.Server do
  @moduledoc "One listed game server: a Basis server or an Overte domain. Held in memory only."

  @fields [
    :platform,
    :external_id,
    :address,
    :name,
    :motd,
    :online,
    :capacity,
    :client_url,
    :last_polled_at,
    :last_seen_at
  ]
  defstruct @fields ++ [status: "unknown"]

  @doc "A server from the given fields. Text from other servers is cut to a fixed length."
  def new(attrs), do: update(%__MODULE__{}, attrs)

  def update(server, attrs) do
    server
    |> struct(Map.take(attrs, [:status | @fields]))
    |> cap(:name, 128)
    |> cap(:motd, 512)
  end

  defp cap(server, key, max) do
    case Map.fetch!(server, key) do
      text when is_binary(text) -> Map.put(server, key, String.slice(text, 0, max))
      _ -> server
    end
  end
end

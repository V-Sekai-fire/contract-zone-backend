# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Lobby.Poller do
  @moduledoc """
  Polls every lobby server's health on a fixed interval (ten minutes), and once at start.
  Set `config :uro, :lobby_poller, false` to leave it out of the supervision tree.
  """
  use GenServer
  require Logger

  @interval_ms 10 * 60 * 1000

  def interval_ms, do: @interval_ms

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :poll)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    try do
      Uro.Lobby.seed_configured()
      :ok = Uro.Lobby.poll()
    rescue
      e -> Logger.warning("lobby poll failed: #{Exception.message(e)}")
    end

    Process.send_after(self(), :poll, @interval_ms)
    {:noreply, state}
  end
end

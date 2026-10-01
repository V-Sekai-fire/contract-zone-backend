# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.AgentTasks.Janitor do
  @moduledoc """
  Frees lapsed claims on the agents' work-stealing queue every
  `:agent_task_janitor_interval` milliseconds (`:uro` config, default one minute), so a
  task whose agent went away can be stolen again.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    {:ok, _count} = Uro.AgentTasks.release_expired()
    schedule()
    {:noreply, state}
  end

  defp schedule do
    Process.send_after(
      self(),
      :sweep,
      Application.get_env(:uro, :agent_task_janitor_interval, 60_000)
    )
  end
end

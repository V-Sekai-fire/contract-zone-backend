# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.VSekai.ZoneJanitor do
  @moduledoc """
  GenServer that culls stale zone records from the database.

  Zone servers send `PUT /shards/:id` heartbeats every ~25 s. Each PUT sets
  `last_put_at` to the current time. This GenServer wakes periodically and
  deletes any row whose `last_put_at` has not been refreshed within the
  staleness window.

  `last_put_at` is set only by explicit PUT calls from the zone server process.
  Phoenix's own heartbeat timer can touch `updated_at` after disconnect; using
  `last_put_at` prevents those stale heartbeats from keeping dead zones alive.

  ## Configuration

  Both keys live under the `:uro` OTP app config:

  - `:stale_zone_cutoff` — `%{amount: integer, calendar_type: String.t()}` — the
    age threshold, e.g. `%{amount: 3, calendar_type: "month"}`.
  - `:stale_zone_interval` — milliseconds between cleanup passes, e.g.
    `30 * 24 * 60 * 60 * 1000` (30 days).

  ## Freshness convention

  `Uro.VSekai.list_fresh_zones/0` applies a separate, tighter filter —
  it returns only zones whose `last_put_at` is within the last 30 seconds:

  ```elixir
  def list_fresh_zones do
    cutoff = DateTime.utc_now() |> DateTime.add(-30, :second)
    from(z in Zone, where: z.last_put_at > ^cutoff) |> Repo.all()
  end
  ```

  A zone that misses two consecutive heartbeats (~50 s) disappears from
  `GET /shards`. The janitor only removes the DB row after the much longer
  staleness window expires.
  """

  use GenServer
  alias Uro.Repo
  import Ecto.Query, only: [from: 2]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{})
  end

  def init(state) do
    schedule_cleanup()
    {:ok, state}
  end

  def handle_info(:cleanup, state) do
    cleanup_stale_zones()
    schedule_cleanup()
    {:noreply, state}
  end

  defp cleanup_stale_zones() do
    stale_zone_cutoff = Application.get_env(:uro, :stale_zone_cutoff)

    query =
      from z in "zones",
        where:
          z.last_put_at <
            from_now(^stale_zone_cutoff[:amount], ^stale_zone_cutoff[:calendar_type]),
        select: z.id

    Repo.delete_all(query)
  end

  defp schedule_cleanup() do
    Process.send_after(self(), :cleanup, Application.get_env(:uro, :stale_zone_interval))
  end
end

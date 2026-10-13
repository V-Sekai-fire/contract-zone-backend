# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Lobby do
  @moduledoc """
  The lobby: Basis servers and Overte domains with their health, refreshed by
  `Uro.Lobby.Poller`.

  The list lives in memory and each poll replaces it whole, capped at `max_servers/0`
  entries, so it takes constant space and writes nothing to the database. Basis servers
  are the configured addresses (`:lobby_basis_servers`), probed one by one. Overte domains
  are whatever the Overte directory lists now; one it stops listing drops off.
  """
  require Logger
  alias Uro.Lobby.{BasisQuery, OverteDirectory, Server}

  @max_servers 10_000
  @key {__MODULE__, :state}
  @empty %{servers: [], polled_at: nil}

  def max_servers, do: @max_servers

  @doc "Every listed server, up first, then by players online."
  def list_servers, do: state().servers

  def list_servers(platform), do: Enum.filter(list_servers(), &(&1.platform == platform))

  @doc "When the last poll ran; nil before the first one."
  def last_poll, do: state().polled_at

  @doc "Records when the last poll ran, so the page can count down to the next one."
  def record_poll(at), do: put_state(%{state() | polled_at: at})

  @doc "Replaces the whole list. Sorts it and keeps at most `max_servers/0` entries."
  def put_servers(servers) do
    count = length(servers)

    if count > @max_servers do
      Logger.warning("lobby: #{count} servers listed, keeping the first #{@max_servers}")
    end

    kept = servers |> Enum.sort_by(&order_key/1) |> Enum.take(@max_servers)
    put_state(%{state() | servers: kept})
  end

  @doc "Empties the list and forgets the last poll."
  def reset, do: put_state(@empty)

  defp state, do: :persistent_term.get(@key, @empty)

  defp put_state(state) do
    :persistent_term.put(@key, state)
    :ok
  end

  defp order_key(s), do: {s.status != "up", -(s.online || -1), s.name}

  @doc "The probes a real poll uses; tests pass their own."
  def default_probes do
    %{
      basis: fn host, port -> BasisQuery.probe(host, port) end,
      overte: &OverteDirectory.fetch/0
    }
  end

  @doc "Refreshes every server once and replaces the list."
  def poll(probes \\ default_probes(), basis_addresses \\ configured_basis()) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    previous = Map.new(list_servers(), &{{&1.platform, &1.external_id}, &1})

    basis = Enum.map(basis_addresses, &poll_basis(probes.basis, &1, previous, now))
    overte = poll_overte(probes.overte, previous, now)

    :ok = put_servers(basis ++ overte)
    record_poll(now)
  end

  defp configured_basis, do: Application.get_env(:uro, :lobby_basis_servers, [])

  defp poll_basis(probe, address, previous, now) do
    last =
      Map.get(previous, {"basis", address}) ||
        Server.new(%{
          platform: "basis",
          external_id: address,
          address: address,
          name: address |> String.split(":") |> hd(),
          client_url: "https://basisvr.org/"
        })

    result =
      case split_address(address) do
        {:ok, host, port} -> probe.(host, port)
        :error -> {:error, :bad_address}
      end

    case result do
      {:ok, info} ->
        Server.update(last, %{
          status: "up",
          name: blank_to(info.name, last.name),
          motd: info.motd,
          online: info.online,
          capacity: info.capacity,
          last_seen_at: now,
          last_polled_at: now
        })

      {:error, _} ->
        Server.update(last, %{status: "down", last_polled_at: now})
    end
  end

  defp poll_overte(fetch, previous, now) do
    case fetch.() do
      {:ok, domains} ->
        Enum.map(domains, fn d ->
          Server.new(Map.merge(d, %{status: "up", last_polled_at: now, last_seen_at: now}))
        end)

      {:error, _} ->
        # The directory itself is unreachable: keep the domains as last seen.
        for {{"overte", _}, server} <- previous, do: server
    end
  end

  defp split_address(address) do
    case String.split(address, ":") do
      [host, port] ->
        case Integer.parse(port) do
          {p, ""} when p in 1..65_535 -> {:ok, host, p}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp blank_to("", fallback), do: fallback
  defp blank_to(nil, fallback), do: fallback
  defp blank_to(value, _), do: value
end

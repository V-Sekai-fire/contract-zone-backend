# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Lobby do
  @moduledoc """
  The OMI lobby: a list of open-metaverse game servers (Basis servers and Overte domains)
  with their health, refreshed by `Uro.Lobby.Poller`.

  Basis servers are listed rows that the poller probes one by one. Overte domains come
  from the Overte directory on every poll; a domain the directory stops listing stays as
  a row and is marked down.
  """
  import Ecto.Query
  alias Uro.Lobby.{BasisQuery, OverteDirectory, Server}
  alias Uro.Repo

  @doc "Every listed server, up first, then by players online."
  def list_servers do
    Server |> order_by(^ordering()) |> Repo.all()
  end

  def list_servers(platform) do
    Server |> where(platform: ^platform) |> order_by(^ordering()) |> Repo.all()
  end

  defp ordering, do: [desc: dynamic([s], s.status == "up"), desc_nulls_last: :online, asc: :name]

  def get_server!(id), do: Repo.get!(Server, id)

  @doc "Inserts a server, or updates the one with the same platform and external id."
  def upsert_server(attrs) do
    platform = attrs[:platform] || attrs["platform"]
    external_id = attrs[:external_id] || attrs["external_id"]

    (Repo.get_by(Server, platform: platform, external_id: external_id) || %Server{})
    |> Server.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "The probes a real poll uses; tests pass their own."
  def default_probes do
    %{
      basis: fn host, port -> BasisQuery.probe(host, port) end,
      overte: &OverteDirectory.fetch/0
    }
  end

  @doc "Refreshes every server once."
  def poll(probes \\ default_probes()) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    poll_basis(probes.basis, now)
    poll_overte(probes.overte, now)
    record_poll(now)
  end

  @doc "Records when the last poll ran, so the page can count down to the next one."
  def record_poll(at) do
    :persistent_term.put({__MODULE__, :last_poll}, at)
    :ok
  end

  @doc "When the last poll ran; nil before the first one."
  def last_poll, do: :persistent_term.get({__MODULE__, :last_poll}, nil)

  defp poll_basis(probe, now) do
    Server
    |> where(platform: "basis")
    |> Repo.all()
    |> Enum.each(fn server ->
      result =
        case split_address(server.address) do
          {:ok, host, port} -> probe.(host, port)
          :error -> {:error, :bad_address}
        end

      attrs =
        case result do
          {:ok, info} ->
            %{
              status: "up",
              name: blank_to(info.name, server.name),
              motd: info.motd,
              online: info.online,
              capacity: info.capacity,
              last_seen_at: now
            }

          {:error, _} ->
            %{status: "down"}
        end

      server |> Server.changeset(Map.put(attrs, :last_polled_at, now)) |> Repo.update!()
    end)
  end

  defp poll_overte(fetch, now) do
    case fetch.() do
      {:ok, domains} ->
        seen =
          for d <- domains do
            {:ok, _} =
              upsert_server(Map.merge(d, %{status: "up", last_polled_at: now, last_seen_at: now}))

            d.external_id
          end

        from(s in Server, where: s.platform == "overte" and s.external_id not in ^seen)
        |> Repo.update_all(set: [status: "down", last_polled_at: now])

      {:error, _} ->
        # The directory itself is unreachable: leave the domains as last seen.
        :ok
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

  @doc "Lists the Basis servers named in config (`:lobby_basis_servers`) if they are absent."
  def seed_configured do
    for address <- Application.get_env(:uro, :lobby_basis_servers, []) do
      host = address |> String.split(":") |> hd()

      if is_nil(Repo.get_by(Server, platform: "basis", external_id: address)) do
        upsert_server(%{
          platform: "basis",
          external_id: address,
          address: address,
          name: host,
          client_url: "https://basisvr.org/"
        })
      end
    end

    :ok
  end
end

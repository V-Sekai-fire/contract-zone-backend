# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Lobby.OverteDirectory do
  @moduledoc """
  Overte domain servers heartbeat to the Overte directory (`mv.overte.org`), which
  publishes each domain's activity and user count through its places API. The lobby
  reads that list rather than probing each domain: a domain is up while the directory
  calls it active.
  """

  @default_url "https://mv.overte.org/server/api/v1/places?per_page=1000"

  def url, do: Application.get_env(:uro, :overte_directory_url, @default_url)

  @doc "Fetches the directory and returns its active domains."
  def fetch do
    case HTTPoison.get(url(), [{"accept", "application/json"}], recv_timeout: 15_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, json} <- Jason.decode(body), do: {:ok, parse_places(json)}

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, {:http_status, code}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  @doc "Active domains from a places reply, one entry per domain."
  def parse_places(%{"status" => "success", "data" => %{"places" => places}})
      when is_list(places) do
    places
    |> Enum.filter(&active_open?/1)
    |> Enum.uniq_by(& &1["domain"]["id"])
    |> Enum.map(&to_server/1)
  end

  def parse_places(_), do: []

  defp active_open?(%{"visibility" => "open", "domain" => %{"active" => true, "id" => id}})
       when is_binary(id),
       do: true

  defp active_open?(_), do: false

  defp to_server(%{"domain" => d} = place) do
    %{
      platform: "overte",
      external_id: d["id"],
      name: d["name"] || place["name"],
      address: "#{d["network_address"]}:#{d["network_port"]}",
      motd: place["description"],
      online: d["num_users"],
      capacity: d["capacity"],
      client_url: "https://overte.org/"
    }
  end
end

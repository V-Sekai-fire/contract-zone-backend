# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Lobby.BasisQuery do
  @moduledoc """
  The Basis server-info probe: one LiteNetLib unconnected message to the server's game
  port (UDP 4296 by default), answered with name, online, capacity and MOTD. The wire
  format is `BasisServerInfoQuery.cs` in the Basis server; the query is padded to
  `ServerInfoMinRequestBytes` (384) or the server drops it.
  """

  # LiteNetLib PacketProperty.UnconnectedMessage, one header byte.
  @unconnected 8
  @query_magic 0xBA515101
  @reply_magic 0xBA515102
  @protocol 1
  @min_request 384

  @doc "The query packet for `nonce`."
  def encode_query(nonce) when nonce in 0..0xFFFF do
    body = <<@query_magic::little-32, @protocol::little-16, nonce::little-16>>
    <<@unconnected, body::binary, :binary.copy(<<0>>, @min_request - byte_size(body))::binary>>
  end

  @doc "Decodes a reply; the nonce must match the query's."
  def decode_reply(
        <<@unconnected, @reply_magic::little-32, _version::little-16, nonce::little-16,
          online::little-16, capacity::little-16, rest::binary>>,
        expected
      ) do
    with :ok <- check_nonce(nonce, expected),
         {:ok, name, rest} <- read_string(rest),
         {:ok, motd, _} <- read_string(rest) do
      {:ok, %{name: name, motd: motd, online: online, capacity: capacity}}
    end
  end

  def decode_reply(_packet, _expected), do: {:error, :bad_reply}

  @doc "Sends one query to `host:port` and waits up to `timeout` ms for the reply."
  def probe(host, port, timeout \\ 3_000) do
    nonce = :rand.uniform(0xFFFF)

    with {:ok, ip} <- resolve(host),
         {:ok, socket} <- :gen_udp.open(0, [:binary, active: false, ip: any_for(ip)]) do
      try do
        :ok = :gen_udp.send(socket, ip, port, encode_query(nonce))
        await(socket, ip, nonce, deadline(timeout))
      after
        :gen_udp.close(socket)
      end
    end
  end

  defp await(socket, ip, nonce, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      {:error, :timeout}
    else
      case :gen_udp.recv(socket, 0, left) do
        {:ok, {^ip, _port, packet}} ->
          case decode_reply(packet, nonce) do
            {:ok, info} -> {:ok, info}
            {:error, _} -> await(socket, ip, nonce, deadline)
          end

        {:ok, _other_sender} ->
          await(socket, ip, nonce, deadline)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp check_nonce(n, n), do: :ok
  defp check_nonce(_, _), do: {:error, :nonce_mismatch}

  # LiteNetLib strings: u16 (byte length + 1), 0 for empty, then UTF-8.
  defp read_string(<<0::little-16, rest::binary>>), do: {:ok, "", rest}

  defp read_string(<<len::little-16, rest::binary>>) when byte_size(rest) >= len - 1 do
    <<s::binary-size(len - 1), rest::binary>> = rest
    if String.valid?(s), do: {:ok, s, rest}, else: {:error, :bad_reply}
  end

  defp read_string(_), do: {:error, :bad_reply}

  defp resolve(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, :nxdomain}
    end
  end

  defp any_for({127, _, _, _}), do: {127, 0, 0, 1}
  defp any_for(_), do: {0, 0, 0, 0}
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Accounts.TOTP do
  @moduledoc """
  RFC 6238 one-time codes over HMAC-SHA1: 30-second steps, 6 digits, one step of clock skew
  either way, and a step at or before the last accepted one refused as a replay.
  """

  import Bitwise

  @period 30
  @digits 6
  @window 1

  def generate_secret, do: :crypto.strong_rand_bytes(20)

  def base32(secret), do: Base.encode32(secret, padding: false)

  def uri(secret, account, issuer \\ "Uro") do
    label = URI.encode(issuer <> ":" <> account, &URI.char_unreserved?/1)

    query =
      URI.encode_query(%{
        "secret" => base32(secret),
        "issuer" => issuer,
        "algorithm" => "SHA1",
        "digits" => @digits,
        "period" => @period
      })

    "otpauth://totp/#{label}?#{query}"
  end

  def step(unix_seconds), do: div(unix_seconds, @period)

  def code(secret, step) do
    mac = :crypto.mac(:hmac, :sha, secret, <<step::unsigned-big-integer-size(64)>>)
    offset = :binary.last(mac) &&& 0x0F
    <<value::unsigned-big-integer-size(32)>> = :binary.part(mac, offset, 4)

    (value &&& 0x7FFFFFFF)
    |> rem(10 ** @digits)
    |> Integer.to_string()
    |> String.pad_leading(@digits, "0")
  end

  @doc "The step `code` matches within the window, provided it is newer than `last_step`."
  def verify(secret, code, unix_seconds, last_step) when is_binary(code) do
    code = String.replace(code, ~r/\s/, "")
    now = step(unix_seconds)

    Enum.find_value(-@window..@window, :error, fn d ->
      s = now + d
      if s > last_step and Plug.Crypto.secure_compare(code(secret, s), code), do: {:ok, s}
    end)
  end

  def verify(_secret, _code, _unix_seconds, _last_step), do: :error
end

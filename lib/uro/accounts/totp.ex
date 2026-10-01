# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Accounts.TOTP do
  @moduledoc """
  RFC 6238 codes from NimbleTOTP (HMAC-SHA1, 30-second steps, 6 digits), accepted one step
  either side of now and refused at or before the last accepted step as a replay.
  """

  @period 30
  @window 1

  def generate_secret, do: NimbleTOTP.secret()

  def base32(secret), do: Base.encode32(secret, padding: false)

  def uri(secret, account, issuer \\ "Uro"),
    do: NimbleTOTP.otpauth_uri("#{issuer}:#{account}", secret, issuer: issuer)

  def step(unix_seconds), do: div(unix_seconds, @period)

  def code(secret, step), do: NimbleTOTP.verification_code(secret, time: step * @period)

  @doc "The step `code` matches within the window, provided it is newer than `last_step`."
  def verify(secret, code, unix_seconds, last_step) when is_binary(code) do
    code = String.replace(code, ~r/\s/, "")

    Enum.find_value(-@window..@window, :error, fn d ->
      t = unix_seconds + d * @period
      if NimbleTOTP.valid?(secret, code, time: t, since: last_step * @period), do: {:ok, step(t)}
    end)
  end

  def verify(_secret, _code, _unix_seconds, _last_step), do: :error
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Registration do
  @moduledoc """
  Whether a new account may be created, by email and password or by a first
  sign-in through an OAuth2 provider. Closed unless `:registration_open` is true.
  """

  def open?, do: Application.get_env(:uro, :registration_open, false) == true

  @doc "The sign-up API key check; an unset or empty key matches nothing."
  def signup_key_valid?(api_key) do
    expected = System.get_env("SIGNUP_API_KEY")

    is_binary(api_key) and is_binary(expected) and expected != "" and
      Plug.Crypto.secure_compare(api_key, expected)
  end
end

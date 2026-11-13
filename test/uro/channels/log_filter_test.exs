# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Channels.LogFilterTest do
  @moduledoc """
  The socket takes the access token as the connect parameter `token`, and Phoenix logs connect
  parameters. The token must not reach a log line.
  """
  use ExUnit.Case, async: true

  test "the socket's token parameter is filtered from logs" do
    assert %{"token" => "[FILTERED]", "zone" => "campus"} =
             Phoenix.Logger.filter_values(%{"token" => "secret-value", "zone" => "campus"})
  end

  test "a password is still filtered" do
    assert %{"password" => "[FILTERED]"} = Phoenix.Logger.filter_values(%{"password" => "p"})
  end
end

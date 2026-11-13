# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.ChannelCase do
  @moduledoc """
  Tests of the socket and its channels through `Uro.Endpoint`.

  Users are real rows and access tokens come from the sign-in route, the way a client
  gets one. `Phoenix.ConnTest` is not imported: its `connect/2` would clash with the
  `connect/2` of `Phoenix.ChannelTest`.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use Uro.RepoCase, async: false

      import Phoenix.ChannelTest
      import Uro.ChannelCase

      @endpoint Uro.Endpoint
    end
  end

  @password "probe-password-1"

  def make_user(prefix) do
    name = "#{prefix}#{System.unique_integer([:positive])}"

    {:ok, user} =
      Uro.Accounts.create(%{
        "email" => "#{name}@example.test",
        "username" => name,
        "display_name" => name,
        "password" => @password
      })

    user
  end

  @doc "Signs `user` in through the endpoint and returns the signed access token."
  def sign_in(user) do
    conn =
      Phoenix.ConnTest.dispatch(
        Phoenix.ConnTest.build_conn(),
        Uro.Endpoint,
        :post,
        "/api/v1/session",
        %{
          "user" => %{"username_or_email" => user.username, "password" => @password}
        }
      )

    200 = conn.status
    %{"data" => %{"access_token" => token}} = Jason.decode!(conn.resp_body)
    token
  end

  @doc "Signs the session of `token` out through the endpoint."
  def sign_out(token) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", token)
    |> Phoenix.ConnTest.dispatch(Uro.Endpoint, :delete, "/api/v1/session")
  end
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.UserSocket do
  @moduledoc """
  The socket of a signed-in user.

  The client sends the access token of its session as the `token` param. It is checked
  the way the HTTP routes check it (`Uro.Plug.Authentication.user_for_access_token/2`),
  and the user must still exist. Any other connection is refused.
  """
  use Phoenix.Socket

  alias Uro.Accounts.User
  alias Uro.Plug.Authentication

  channel "zone:*", Uro.ZoneChannel

  def connect(%{"token" => token}, socket, _connect_info) do
    with {:ok, %User{id: id}} <- Authentication.user_for_access_token(token),
         %User{} = user <- Uro.Repo.get(User, id) do
      {:ok, assign(socket, :user, user)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  def id(socket), do: "user_socket:#{socket.assigns.user.id}"
end

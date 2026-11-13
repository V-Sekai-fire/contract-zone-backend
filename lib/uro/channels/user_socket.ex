# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.UserSocket do
  use Phoenix.Socket

  alias Uro.Accounts.User
  alias Uro.Plug.Authentication

  channel "zone:*", Uro.ZoneChannel

  # The client sends the access token of its session as the `token` param. It is checked
  # the way the HTTP routes check it, and the user must still exist.
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

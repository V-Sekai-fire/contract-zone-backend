# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.UserSocketTest do
  @moduledoc """
  The socket admits a connection only with the access token of a signed-in user, the same
  token the HTTP routes take in the `authorization` header.
  """
  use Uro.ChannelCase

  alias Uro.UserSocket

  test "a valid access token connects, assigns the user and names the socket" do
    user = make_user("socket")
    token = sign_in(user)

    assert {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert socket.assigns.user.id == user.id
    assert socket.id == "user_socket:#{user.id}"
  end

  test "control: a connection with no token is refused" do
    assert connect(UserSocket, %{}) == :error
  end

  test "control: a garbage token is refused" do
    assert connect(UserSocket, %{"token" => "garbage"}) == :error
  end

  test "control: a token that is not a string is refused" do
    assert connect(UserSocket, %{"token" => %{"a" => 1}}) == :error
  end

  test "control: a token is refused after its session is signed out" do
    token = sign_in(make_user("gone"))
    assert {:ok, _socket} = connect(UserSocket, %{"token" => token})

    sign_out(token)
    assert connect(UserSocket, %{"token" => token}) == :error
  end

  test "control: a token is refused once its user no longer exists" do
    user = make_user("deleted")
    token = sign_in(user)
    Uro.Repo.delete!(user)

    assert connect(UserSocket, %{"token" => token}) == :error
  end
end

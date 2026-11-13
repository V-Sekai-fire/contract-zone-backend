# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Plug.Authentication do
  @moduledoc false

  use Pow.Plug.Base

  alias Plug.Conn
  alias Pow.Config
  alias Pow.Plug
  alias PowPersistentSession.Store.PersistentSessionCache
  alias Uro.Accounts.User

  # The lifetime of the session.
  @session_lifetime :timer.hours(168)

  # Renew the session if it expires in less than this.
  @session_renewal @session_lifetime - :timer.hours(1)

  @doc """
  The user a signed access token belongs to, for callers with no `Plug.Conn` (the socket).

  This is the check `fetch/2` makes on a request: the signature is verified with the
  endpoint's secret key base and the token is looked up in the session store. The session
  is not renewed here.
  """
  @spec user_for_access_token(term(), Config.t()) :: {:ok, User.t()} | {:error, :invalid_token}
  def user_for_access_token(signed_access_token, config \\ [otp_app: :uro]) do
    conn = %Conn{secret_key_base: Uro.Endpoint.config(:secret_key_base)}

    case lookup(conn, signed_access_token, config) do
      {:ok, {user, _metadata, _access_token}} -> {:ok, user}
      {:error, :invalid_token} -> {:error, :invalid_token}
    end
  end

  # Verifies the signature and finds the session; shared by `fetch/2` and the socket.
  defp lookup(conn, signed_access_token, config) when is_binary(signed_access_token) do
    with {:ok, access_token} <- verify_token(conn, signed_access_token, config),
         {%User{} = user, metadata} <-
           PersistentSessionCache.get(store_config(config), access_token) do
      {:ok, {user, metadata, access_token}}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp lookup(_conn, _signed_access_token, _config), do: {:error, :invalid_token}

  @impl true
  def fetch(%Conn{} = conn, config) do
    with {:ok, signed_access_token} <- fetch_access_token(conn),
         {:ok, {user, metadata, access_token}} <- lookup(conn, signed_access_token, config),
         expires_in <- metadata[:expires_at] |> DateTime.diff(DateTime.utc_now(), :millisecond),
         conn <-
           conn
           |> Conn.assign(:access_token, signed_access_token)
           |> Conn.assign(:access_token_unsigned, access_token)
           |> Conn.assign(
             :access_token_expires_in,
             expires_in
           ),
         {conn, user} <- maybe_renew(conn, {user, metadata}, config) do
      {conn, user}
    else
      _ -> {conn, nil}
    end
  end

  defp maybe_renew(%Conn{} = conn, {%User{} = user, metadata}, config) do
    expires_in =
      metadata[:expires_at]
      |> DateTime.diff(DateTime.utc_now(), :millisecond)

    with true <- expires_in < @session_renewal,
         {conn, user} <- load_and_create_session(conn, {[id: user.id], metadata}, config) do
      {conn, user}
    else
      _ -> {conn, user}
    end
  end

  @impl true
  def create(%Conn{} = conn, %User{} = user, config) do
    store_config =
      store_config(config)
      |> Keyword.put(:ttl, @session_lifetime)

    access_token = Pow.UUID.generate()
    signed_access_token = sign_token(conn, access_token, config)

    conn =
      conn
      |> Conn.assign(:access_token, signed_access_token)
      |> Conn.assign(:access_token_unsigned, access_token)
      |> Conn.assign(:access_token_expires_in, store_config[:ttl])
      |> Conn.put_resp_cookie(
        "session",
        signed_access_token,
        max_age: store_config[:ttl]
      )
      |> Conn.register_before_send(fn conn ->
        expires_at = DateTime.add(DateTime.utc_now(), store_config[:ttl], :millisecond)

        PersistentSessionCache.put(
          store_config,
          access_token,
          {user,
           [
             expires_at: expires_at
           ]}
        )

        conn
      end)

    {conn, user}
  end

  @impl true
  @spec delete(Conn.t(), Config.t()) :: Conn.t()
  def delete(conn, config) do
    store_config = store_config(config)

    with {:ok, signed_access_token} <- fetch_access_token(conn),
         {:ok, access_token} <- verify_token(conn, signed_access_token, config),
         :ok <- PersistentSessionCache.delete(store_config, access_token),
         conn <- Conn.delete_resp_cookie(conn, "session") do
      conn
    else
      _ -> conn
    end
  end

  defp load_and_create_session(conn, {clauses, _metadata}, config) do
    case Pow.Operations.get_by(clauses, config) do
      nil -> {conn, nil}
      user -> create(conn, user, config)
    end
  end

  defp sign_token(conn, token, config) do
    Plug.sign_token(conn, signing_salt(), token, config)
  end

  defp signing_salt(), do: Atom.to_string(__MODULE__)

  defp fetch_access_token(conn) do
    case Conn.get_req_header(conn, "authorization") do
      ["Bearer" <> " " <> access_token | _] ->
        {:ok, access_token}

      [access_token | _] ->
        {:ok, access_token}

      _ ->
        case conn.cookies do
          %{"session" => access_token} when is_binary(access_token) ->
            {:ok, access_token}

          _ ->
            :error
        end
    end
  end

  defp verify_token(conn, token, config),
    do: Plug.verify_token(conn, signing_salt(), token, config)

  defp store_config(config) do
    backend = Config.get(config, :cache_store_backend)
    [backend: backend, pow_config: config]
  end
end

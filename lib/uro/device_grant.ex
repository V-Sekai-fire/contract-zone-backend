# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.DeviceGrant do
  @moduledoc """
  RFC 8628's device authorization grant, for a headset or console that cannot type a password:
  the device shows a short code and a QR of the verification URI, a signed-in person approves it
  on their phone, and the device's polling turns into a session. A device code is single use.
  """

  import Ecto.Query

  alias Uro.Accounts.User
  alias Uro.DeviceGrant.Approval
  alias Uro.DeviceGrant.Authorization
  alias Uro.DeviceGrant.Denial
  alias Uro.DeviceGrant.Poll
  alias Uro.Repo

  @grant_type "urn:ietf:params:oauth:grant-type:device_code"
  @expires_in 600
  @interval 5
  @alphabet ~c"BCDFGHJKLMNPQRSTVWXZ"

  def grant_type, do: @grant_type

  @doc "A new authorization for `client_id`: the device's secret code and the code to type."
  def start(client_id, now \\ now())

  def start(client_id, now) when is_binary(client_id) and client_id != "" do
    Repo.delete_all(from(a in Authorization, where: a.expires_at < ^now))
    device_code = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    user_code = for _ <- 1..8, into: "", do: <<Enum.random(@alphabet)>>

    Repo.insert!(%Authorization{
      device_code_hash: hash(device_code),
      user_code: user_code,
      client_id: client_id,
      interval_s: @interval,
      expires_at: DateTime.add(now, @expires_in),
      created_at: now
    })

    uri = Application.fetch_env!(:uro, :device_verification_uri)
    shown = display(user_code)

    {:ok,
     %{
       device_code: device_code,
       user_code: shown,
       verification_uri: uri,
       verification_uri_complete: uri <> "?" <> URI.encode_query(%{"user_code" => shown}),
       expires_in: @expires_in,
       interval: @interval
     }}
  end

  def start(_client_id, _now), do: {:error, :invalid_client}

  @doc "What a person approving `user_code` is told: which client asks, and until when."
  def lookup(user_code, now \\ now()) do
    with {:ok, auth} <- pending(user_code, now) do
      {:ok, %{client_id: auth.client_id, expires_at: auth.expires_at}}
    end
  end

  def approve(%User{id: uid}, user_code, now \\ now()) do
    with {:ok, auth} <- pending(user_code, now) do
      Repo.insert!(%Approval{authorization_id: auth.id, user_id: uid, approved_at: now})
      :ok
    end
  end

  def deny(%User{}, user_code, now \\ now()) do
    with {:ok, auth} <- pending(user_code, now) do
      Repo.insert!(%Denial{authorization_id: auth.id, denied_at: now})
      :ok
    end
  end

  @doc """
  One poll of the token endpoint: the approving user, or the RFC 8628 error code a device acts
  on (authorization_pending, slow_down, access_denied, expired_token, invalid_grant).
  """
  def poll(params, now \\ now())

  def poll(%{"grant_type" => @grant_type, "device_code" => code} = params, now)
      when is_binary(code) do
    case Repo.get_by(Authorization, device_code_hash: hash(code)) do
      nil ->
        {:error, "invalid_grant"}

      %Authorization{} = auth ->
        cond do
          params["client_id"] not in [nil, auth.client_id] -> {:error, "invalid_client"}
          DateTime.compare(now, auth.expires_at) != :lt -> {:error, "expired_token"}
          too_soon?(auth, now) -> slow_down(auth, now)
          true -> decide(auth, now)
        end
    end
  end

  def poll(%{"grant_type" => @grant_type}, _now), do: {:error, "invalid_request"}
  def poll(_params, _now), do: {:error, "unsupported_grant_type"}

  defp decide(%Authorization{id: id} = auth, now) do
    polled(auth, now)

    cond do
      Repo.exists?(from(d in Denial, where: d.authorization_id == ^id)) ->
        Repo.delete_all(from(a in Authorization, where: a.id == ^id))
        {:error, "access_denied"}

      approval = Repo.get(Approval, id) ->
        case Repo.delete_all(from(a in Authorization, where: a.id == ^id)) do
          {1, _} -> {:ok, Repo.get!(User, approval.user_id)}
          _ -> {:error, "invalid_grant"}
        end

      true ->
        {:error, "authorization_pending"}
    end
  end

  defp too_soon?(%Authorization{id: id, interval_s: interval}, now) do
    case Repo.get(Poll, id) do
      %Poll{polled_at: at} -> DateTime.diff(now, at) < interval
      nil -> false
    end
  end

  # RFC 8628 3.5: a device polling too fast is told to slow down, and its interval grows by 5 s.
  defp slow_down(%Authorization{id: id} = auth, now) do
    Repo.update_all(from(a in Authorization, where: a.id == ^id), inc: [interval_s: 5])
    polled(auth, now)
    {:error, "slow_down"}
  end

  defp polled(%Authorization{id: id}, now) do
    Repo.insert!(%Poll{authorization_id: id, polled_at: now},
      on_conflict: [set: [polled_at: now]],
      conflict_target: :authorization_id
    )
  end

  defp pending(user_code, now) when is_binary(user_code) do
    code = user_code |> String.upcase() |> String.replace(~r/[^A-Z]/, "")

    query =
      from(a in Authorization,
        left_join: ap in Approval,
        on: ap.authorization_id == a.id,
        left_join: dn in Denial,
        on: dn.authorization_id == a.id,
        where:
          a.user_code == ^code and a.expires_at > ^now and is_nil(ap.authorization_id) and
            is_nil(dn.authorization_id)
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      auth -> {:ok, auth}
    end
  end

  defp pending(_user_code, _now), do: {:error, :not_found}

  defp display(<<a::binary-size(4), b::binary-size(4)>>), do: a <> "-" <> b

  defp hash(device_code), do: :crypto.hash(:sha256, device_code)

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.SecondFactor do
  @moduledoc """
  2-step sign-in by authenticator app, with single-use backup codes. A user with a confirmed
  authenticator signs in with their password and either a current code or one backup code.
  """

  import Ecto.Query

  alias Uro.Accounts.TOTP
  alias Uro.Accounts.User
  alias Uro.Repo
  alias Uro.SecondFactor.BackupCode
  alias Uro.SecondFactor.TotpCredential
  alias Uro.SecondFactor.TotpEnrollment

  @backup_codes 10
  @alphabet ~c"ABCDEFGHJKMNPQRSTVWXYZ23456789"

  def enabled?(%User{id: id}),
    do: Repo.exists?(from(t in TotpCredential, where: t.user_id == ^id))

  @doc "Starts enrolment: a fresh secret, unconfirmed until `confirm_totp/3` sees a code from it."
  def begin_totp(%User{id: id} = user) do
    if enabled?(user) do
      {:error, :already_enabled}
    else
      secret = TOTP.generate_secret()

      Repo.insert!(%TotpEnrollment{user_id: id, sealed_secret: seal(secret)},
        on_conflict: :replace_all,
        conflict_target: :user_id
      )

      {:ok, %{secret: TOTP.base32(secret), uri: TOTP.uri(secret, user.email || user.username)}}
    end
  end

  @doc "Confirms enrolment with a code from the new secret and returns the backup codes, once."
  def confirm_totp(%User{id: id}, code, now \\ System.os_time(:second)) do
    with %TotpEnrollment{sealed_secret: sealed} <-
           Repo.get(TotpEnrollment, id) || {:error, :no_enrollment},
         secret = unseal(sealed),
         {:ok, step} <- TOTP.verify(secret, code, now, 0) |> invalid_if_error() do
      codes = Enum.map(1..@backup_codes, fn _ -> new_backup_code() end)

      Repo.transaction(fn ->
        Repo.insert!(%TotpCredential{user_id: id, sealed_secret: sealed, last_step: step})
        Repo.delete_all(from(e in TotpEnrollment, where: e.user_id == ^id))
        Repo.delete_all(from(b in BackupCode, where: b.user_id == ^id))
        Enum.each(codes, &Repo.insert!(%BackupCode{user_id: id, code_hash: code_hash(&1)}))
        codes
      end)
    end
  end

  @doc "Removes the authenticator and its backup codes, given a current code or a backup code."
  def disable_totp(%User{id: id} = user, credentials, now \\ System.os_time(:second)) do
    if enabled?(user) do
      with :ok <- check(user, credentials, now) do
        Repo.transaction(fn ->
          Repo.delete_all(from(t in TotpCredential, where: t.user_id == ^id))
          Repo.delete_all(from(b in BackupCode, where: b.user_id == ^id))
        end)

        :ok
      end
    else
      {:error, :not_enabled}
    end
  end

  @doc """
  The second step of signing in. A user without an authenticator passes; one with it needs a
  `totp_code` newer than the last accepted, or a `backup_code`, which is spent.
  """
  def check(%User{id: id}, credentials, now \\ System.os_time(:second)) do
    case Repo.get(TotpCredential, id) do
      nil ->
        :ok

      %TotpCredential{} = cred ->
        cond do
          is_binary(credentials["totp_code"]) -> spend_totp(cred, credentials["totp_code"], now)
          is_binary(credentials["backup_code"]) -> spend_backup(id, credentials["backup_code"])
          true -> {:error, :second_factor_required}
        end
    end
  end

  defp spend_totp(%TotpCredential{user_id: id, last_step: last} = cred, code, now) do
    with {:ok, step} <-
           TOTP.verify(unseal(cred.sealed_secret), code, now, last) |> invalid_if_error() do
      query = from(t in TotpCredential, where: t.user_id == ^id and t.last_step < ^step)

      case Repo.update_all(query, set: [last_step: step]) do
        {1, _} -> :ok
        _ -> {:error, :invalid_second_factor}
      end
    end
  end

  defp spend_backup(id, code) do
    query = from(b in BackupCode, where: b.user_id == ^id and b.code_hash == ^code_hash(code))

    case Repo.delete_all(query) do
      {1, _} -> :ok
      _ -> {:error, :invalid_second_factor}
    end
  end

  defp invalid_if_error(:error), do: {:error, :invalid_second_factor}
  defp invalid_if_error(ok), do: ok

  defp new_backup_code do
    chars = for _ <- 1..8, do: Enum.random(@alphabet)
    {a, b} = Enum.split(chars, 4)
    "#{a}-#{b}"
  end

  defp code_hash(code) do
    normal = code |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")
    :crypto.mac(:hmac, :sha256, key("uro backup codes"), normal)
  end

  defp seal(secret), do: Plug.Crypto.encrypt(key_base(), "uro totp", secret)

  defp unseal(sealed) do
    {:ok, secret} = Plug.Crypto.decrypt(key_base(), "uro totp", sealed, max_age: :infinity)
    secret
  end

  defp key(salt), do: Plug.Crypto.KeyGenerator.generate(key_base(), salt)

  defp key_base, do: Uro.Endpoint.config(:secret_key_base)
end

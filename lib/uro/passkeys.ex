# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Passkeys do
  @moduledoc """
  Passkey sign-in by WebAuthn through wax_: discoverable credentials with user verification
  required, so a passkey stands for both sign-in steps. Each challenge is a row spent on first
  use, which is what keeps a captured assertion from being replayed.
  """

  import Ecto.Query

  alias Uro.Accounts.User
  alias Uro.Passkeys.LoginChallenge
  alias Uro.Passkeys.Passkey
  alias Uro.Passkeys.RegistrationChallenge
  alias Uro.Repo

  # ES256, EdDSA, RS256.
  @algorithms [-7, -8, -257]
  @stale_after 600

  @doc "Options for `navigator.credentials.create()`, and the id of the challenge they carry."
  def registration_options(%User{id: uid} = user) do
    challenge = Wax.new_registration_challenge(wax_opts(attestation: "none"))
    sweep()

    row =
      Repo.insert!(%RegistrationChallenge{
        user_id: uid,
        challenge: :erlang.term_to_binary(challenge)
      })

    existing = Repo.all(from(p in Passkey, where: p.user_id == ^uid, select: p.credential_id))

    {:ok,
     %{
       challenge_id: row.id,
       public_key: %{
         challenge: b64(challenge.bytes),
         rp: %{id: challenge.rp_id, name: "Uro"},
         user: %{
           id: b64(Ecto.UUID.dump!(uid)),
           name: user.email || user.username,
           displayName: user.display_name || user.username
         },
         pubKeyCredParams: Enum.map(@algorithms, &%{type: "public-key", alg: &1}),
         authenticatorSelection: %{
           residentKey: "required",
           requireResidentKey: true,
           userVerification: "required"
         },
         attestation: "none",
         timeout: challenge.timeout * 1000,
         excludeCredentials: Enum.map(existing, &%{type: "public-key", id: b64(&1)})
       }
     }}
  end

  @doc "Verifies a new credential against its challenge and keeps it."
  def register(%User{id: uid}, %{
        "challenge_id" => cid,
        "attestation_object" => att_object,
        "client_data_json" => client_data
      }) do
    query = from(c in RegistrationChallenge, where: c.id == ^cid and c.user_id == ^uid)

    with {:ok, challenge} <- spend(RegistrationChallenge, query),
         {:ok, att_object} <- d64(att_object),
         {:ok, client_data} <- d64(client_data),
         {:ok, {auth_data, _attestation}} <-
           Wax.register(att_object, client_data, challenge) |> wax(),
         %{credential_id: cred_id, credential_public_key: key} <-
           auth_data.attested_credential_data do
      %Passkey{
        user_id: uid,
        credential_id: cred_id,
        cose_key: :erlang.term_to_binary(key),
        sign_count: auth_data.sign_count
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:credential_id)
      |> Repo.insert()
    end
  end

  def register(_user, _params), do: {:error, :invalid_passkey}

  def list(%User{id: uid}) do
    Repo.all(from(p in Passkey, where: p.user_id == ^uid, order_by: p.created_at))
  end

  def delete(%User{id: uid}, id) do
    case Repo.delete_all(from(p in Passkey, where: p.id == ^id and p.user_id == ^uid)) do
      {1, _} -> :ok
      _ -> {:error, :not_found}
    end
  end

  @doc "Options for `navigator.credentials.get()` with no account named, and their challenge id."
  def login_options do
    challenge = Wax.new_authentication_challenge(wax_opts([]))
    sweep()
    row = Repo.insert!(%LoginChallenge{challenge: :erlang.term_to_binary(challenge)})

    {:ok,
     %{
       challenge_id: row.id,
       public_key: %{
         challenge: b64(challenge.bytes),
         rpId: challenge.rp_id,
         userVerification: "required",
         timeout: challenge.timeout * 1000,
         allowCredentials: []
       }
     }}
  end

  @doc "The user an assertion signs in, once its challenge, signature and count all hold."
  def authenticate(
        %{
          "challenge_id" => cid,
          "credential_id" => cred,
          "authenticator_data" => auth_data,
          "client_data_json" => client_data,
          "signature" => sig
        } = params
      ) do
    with {:ok, challenge} <-
           spend(LoginChallenge, from(c in LoginChallenge, where: c.id == ^cid)),
         {:ok, cred} <- d64(cred),
         {:ok, auth_data} <- d64(auth_data),
         {:ok, client_data} <- d64(client_data),
         {:ok, sig} <- d64(sig),
         %Passkey{} = passkey <- find(cred),
         :ok <- same_user(passkey, params["user_handle"]),
         key = :erlang.binary_to_term(passkey.cose_key, [:safe]),
         {:ok, verified} <-
           Wax.authenticate(cred, auth_data, sig, client_data, challenge, [{cred, key}]) |> wax(),
         :ok <- advance(passkey, verified.sign_count) do
      {:ok, passkey.user}
    end
  end

  def authenticate(_params), do: {:error, :invalid_passkey}

  defp find(cred) do
    Repo.one(from(p in Passkey, where: p.credential_id == ^cred, preload: [:user])) ||
      {:error, :invalid_passkey}
  end

  defp same_user(_passkey, nil), do: :ok

  defp same_user(%Passkey{user_id: uid}, handle) do
    if d64(handle) == {:ok, Ecto.UUID.dump!(uid)}, do: :ok, else: {:error, :invalid_passkey}
  end

  # Authenticators that keep no counter report 0 every time; any other count must rise.
  defp advance(%Passkey{sign_count: 0}, 0), do: :ok

  defp advance(%Passkey{id: id}, count) do
    query = from(p in Passkey, where: p.id == ^id and p.sign_count < ^count)

    case Repo.update_all(query, set: [sign_count: count]) do
      {1, _} -> :ok
      _ -> {:error, :invalid_passkey}
    end
  end

  defp spend(schema, query) do
    with %{id: id, challenge: bin} <- Repo.one(query) || {:error, :invalid_passkey},
         {1, _} <- Repo.delete_all(from(c in schema, where: c.id == ^id)) do
      {:ok, :erlang.binary_to_term(bin, [:safe])}
    else
      {0, _} -> {:error, :invalid_passkey}
      error -> error
    end
  end

  defp sweep do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after)
    Repo.delete_all(from(c in RegistrationChallenge, where: c.created_at < ^cutoff))
    Repo.delete_all(from(c in LoginChallenge, where: c.created_at < ^cutoff))
  end

  defp wax({:error, _exception}), do: {:error, :invalid_passkey}
  defp wax(ok), do: ok

  defp wax_opts(extra) do
    config = Application.fetch_env!(:uro, :webauthn)

    [origin: config[:origin], rp_id: config[:rp_id], user_verification: "required"] ++ extra
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp d64(text) when is_binary(text) do
    case Base.url_decode64(text, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid_passkey}
    end
  end

  defp d64(_), do: {:error, :invalid_passkey}
end

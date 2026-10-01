# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.PasskeyController do
  use Uro, :controller

  alias OpenApiSpex.Schema
  alias Uro.Accounts.User
  alias Uro.Accounts.UserPrivilegeRuleset
  alias Uro.Helpers
  alias Uro.Passkeys
  alias Uro.Repo

  action_fallback(Uro.FallbackController)

  tags(["authentication"])

  @options %Schema{
    type: :object,
    properties: %{
      data: %Schema{
        type: :object,
        properties: %{
          challenge_id: %Schema{type: :string, format: :uuid},
          public_key: %Schema{
            type: :object,
            description: "WebAuthn options, binary fields base64url."
          }
        }
      }
    }
  }

  @b64 %Schema{type: :string, description: "base64url, no padding"}

  operation(:registration_challenge,
    operation_id: "passkeyRegistrationChallenge",
    summary: "Options to create a passkey",
    responses: [ok: {"", "application/json", @options}]
  )

  def registration_challenge(conn, _params) do
    with {:ok, options} <- Passkeys.registration_options(Helpers.Auth.get_current_user(conn)) do
      json(conn, %{data: options})
    end
  end

  operation(:register,
    operation_id: "registerPasskey",
    summary: "Register a passkey",
    request_body:
      {"", "application/json",
       %Schema{
         type: :object,
         required: [:challenge_id, :attestation_object, :client_data_json],
         properties: %{
           challenge_id: %Schema{type: :string, format: :uuid},
           attestation_object: @b64,
           client_data_json: @b64
         }
       }},
    responses: [created: {"", "application/json", %Schema{type: :object}}]
  )

  def register(conn, params) do
    with {:ok, passkey} <- Passkeys.register(Helpers.Auth.get_current_user(conn), params) do
      conn |> put_status(:created) |> json(%{data: render_passkey(passkey)})
    end
  end

  operation(:index,
    operation_id: "listPasskeys",
    summary: "The signed-in user's passkeys",
    responses: [ok: {"", "application/json", %Schema{type: :object}}]
  )

  def index(conn, _params) do
    passkeys = Passkeys.list(Helpers.Auth.get_current_user(conn))
    json(conn, %{data: Enum.map(passkeys, &render_passkey/1)})
  end

  operation(:delete,
    operation_id: "deletePasskey",
    summary: "Remove a passkey",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [ok: {"", "application/json", %Schema{type: :object}}]
  )

  def delete(conn, %{"id" => id}) do
    with :ok <- Passkeys.delete(Helpers.Auth.get_current_user(conn), id) do
      json(conn, %{data: %{}})
    end
  end

  operation(:login_challenge,
    operation_id: "passkeyLoginChallenge",
    summary: "Options to sign in with a passkey",
    responses: [ok: {"", "application/json", @options}]
  )

  def login_challenge(conn, _params) do
    with {:ok, options} <- Passkeys.login_options() do
      json(conn, %{data: options})
    end
  end

  operation(:login,
    operation_id: "loginWithPasskey",
    summary: "Sign in with a passkey",
    request_body:
      {"", "application/json",
       %Schema{
         type: :object,
         required: [
           :challenge_id,
           :credential_id,
           :authenticator_data,
           :client_data_json,
           :signature
         ],
         properties: %{
           challenge_id: %Schema{type: :string, format: :uuid},
           credential_id: @b64,
           authenticator_data: @b64,
           client_data_json: @b64,
           signature: @b64,
           user_handle: @b64
         }
       }},
    responses: [ok: {"", "application/json", %Schema{type: :object}}]
  )

  def login(conn, params) do
    with {:ok, %User{locked_at: nil} = user} <- Passkeys.authenticate(params) |> unlocked() do
      user = Repo.preload(user, :user_privilege_ruleset)
      conn = Pow.Plug.create(conn, user)

      json(conn, %{
        data: %{
          access_token: conn.assigns[:access_token],
          renewal_token: conn.assigns[:access_token],
          user: User.to_json_schema(user, conn),
          user_privilege_ruleset: UserPrivilegeRuleset.to_json_schema(user.user_privilege_ruleset)
        }
      })
    end
  end

  defp unlocked({:ok, %User{locked_at: nil}} = ok), do: ok
  defp unlocked({:ok, %User{}}), do: {:error, :account_locked}
  defp unlocked(error), do: error

  defp render_passkey(passkey) do
    %{
      id: passkey.id,
      credential_id: Base.url_encode64(passkey.credential_id, padding: false),
      created_at: passkey.created_at
    }
  end
end

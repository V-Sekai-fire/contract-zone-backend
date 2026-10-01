# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.DeviceGrantController do
  use Uro, :controller

  alias OpenApiSpex.Schema
  alias Uro.Accounts.User
  alias Uro.Accounts.UserPrivilegeRuleset
  alias Uro.DeviceGrant
  alias Uro.Helpers
  alias Uro.Repo

  action_fallback(Uro.FallbackController)

  tags(["authentication"])

  @user_code %Schema{type: :string, description: "The code the device shows, e.g. WDJB-MJHT."}

  operation(:code,
    operation_id: "deviceAuthorization",
    summary: "Start a device sign-in (RFC 8628)",
    request_body:
      {"", "application/json",
       %Schema{
         type: :object,
         required: [:client_id],
         properties: %{client_id: %Schema{type: :string}}
       }},
    responses: [ok: {"", "application/json", %Schema{type: :object}}]
  )

  def code(conn, params) do
    with {:ok, authorization} <- DeviceGrant.start(params["client_id"]) do
      json(conn, authorization)
    end
  end

  operation(:token,
    operation_id: "deviceToken",
    summary: "Poll for the device's session (RFC 8628)",
    request_body:
      {"", "application/json",
       %Schema{
         type: :object,
         required: [:grant_type, :device_code],
         properties: %{
           grant_type: %Schema{type: :string, enum: [DeviceGrant.grant_type()]},
           device_code: %Schema{type: :string},
           client_id: %Schema{type: :string}
         }
       }},
    responses: [
      ok: {"", "application/json", %Schema{type: :object}},
      bad_request: {"RFC 8628 error code", "application/json", %Schema{type: :object}}
    ]
  )

  def token(conn, params) do
    case DeviceGrant.poll(params) do
      {:ok, %User{locked_at: nil} = user} ->
        user = Repo.preload(user, :user_privilege_ruleset)
        conn = Pow.Plug.create(conn, user)

        json(conn, %{
          data: %{
            access_token: conn.assigns[:access_token],
            renewal_token: conn.assigns[:access_token],
            user: User.to_json_schema(user, conn),
            user_privilege_ruleset:
              UserPrivilegeRuleset.to_json_schema(user.user_privilege_ruleset)
          }
        })

      {:ok, %User{}} ->
        conn |> put_status(:bad_request) |> json(%{error: "access_denied"})

      {:error, code} ->
        conn |> put_status(:bad_request) |> json(%{error: code})
    end
  end

  operation(:show,
    operation_id: "deviceAuthorizationInfo",
    summary: "Which client a user code belongs to",
    parameters: [user_code: [in: :query, type: :string, required: true]],
    responses: [ok: {"", "application/json", %Schema{type: :object}}]
  )

  def show(conn, params) do
    with {:ok, info} <- DeviceGrant.lookup(params["user_code"]) do
      json(conn, %{data: info})
    end
  end

  operation(:approve,
    operation_id: "approveDevice",
    summary: "Approve a device sign-in",
    request_body:
      {"", "application/json",
       %Schema{type: :object, required: [:user_code], properties: %{user_code: @user_code}}},
    responses: [ok: {"", "application/json", %Schema{type: :object}}]
  )

  def approve(conn, params) do
    with :ok <- DeviceGrant.approve(Helpers.Auth.get_current_user(conn), params["user_code"]) do
      json(conn, %{data: %{}})
    end
  end

  operation(:deny,
    operation_id: "denyDevice",
    summary: "Refuse a device sign-in",
    request_body:
      {"", "application/json",
       %Schema{type: :object, required: [:user_code], properties: %{user_code: @user_code}}},
    responses: [ok: {"", "application/json", %Schema{type: :object}}]
  )

  def deny(conn, params) do
    with :ok <- DeviceGrant.deny(Helpers.Auth.get_current_user(conn), params["user_code"]) do
      json(conn, %{data: %{}})
    end
  end
end

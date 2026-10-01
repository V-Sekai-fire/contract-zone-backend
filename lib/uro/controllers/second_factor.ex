# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.SecondFactorController do
  use Uro, :controller

  alias OpenApiSpex.Schema
  alias Uro.Helpers
  alias Uro.SecondFactor

  action_fallback(Uro.FallbackController)

  tags(["authentication"])

  @code %Schema{type: :string, description: "A 6-digit authenticator code."}

  operation(:begin_totp,
    operation_id: "beginTotp",
    summary: "Start authenticator enrolment",
    responses: [
      ok:
        {"", "application/json",
         %Schema{
           type: :object,
           properties: %{
             data: %Schema{
               type: :object,
               properties: %{secret: %Schema{type: :string}, uri: %Schema{type: :string}}
             }
           }
         }}
    ]
  )

  def begin_totp(conn, _params) do
    with {:ok, enrolment} <- SecondFactor.begin_totp(Helpers.Auth.get_current_user(conn)) do
      json(conn, %{data: enrolment})
    end
  end

  operation(:confirm_totp,
    operation_id: "confirmTotp",
    summary: "Confirm authenticator enrolment",
    request_body:
      {"", "application/json",
       %Schema{type: :object, required: [:code], properties: %{code: @code}}},
    responses: [
      ok:
        {"Backup codes, shown once", "application/json",
         %Schema{
           type: :object,
           properties: %{
             data: %Schema{
               type: :object,
               properties: %{backup_codes: %Schema{type: :array, items: %Schema{type: :string}}}
             }
           }
         }}
    ]
  )

  def confirm_totp(conn, %{"code" => code}) do
    with {:ok, codes} <- SecondFactor.confirm_totp(Helpers.Auth.get_current_user(conn), code) do
      json(conn, %{data: %{backup_codes: codes}})
    end
  end

  def confirm_totp(_conn, _params), do: {:error, :invalid_second_factor}

  operation(:disable_totp,
    operation_id: "disableTotp",
    summary: "Remove the authenticator",
    request_body:
      {"", "application/json",
       %Schema{
         type: :object,
         properties: %{totp_code: @code, backup_code: %Schema{type: :string}}
       }},
    responses: [ok: {"", "application/json", %Schema{type: :object}}]
  )

  def disable_totp(conn, params) do
    with :ok <- SecondFactor.disable_totp(Helpers.Auth.get_current_user(conn), params) do
      json(conn, %{data: %{}})
    end
  end
end

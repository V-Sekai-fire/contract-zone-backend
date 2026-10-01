# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.AdminController do
  use Uro, :controller

  alias OpenApiSpex.Schema

  tags(["admin"])

  operation(:status,
    operation_id: "getAdminStatus",
    summary: "Get Admin status",
    responses: [
      ok: {
        "",
        "application/json",
        %Schema{
          type: :object,
          properties: %{
            status: %Schema{
              type: :object,
              properties: %{
                is_admin: %Schema{
                  type: :string,
                  enum: ["true", "false"]
                }
              }
            }
          }
        }
      }
    ]
  )

  def status(conn, _params) do
    json(conn, %{status: %{is_admin: "true"}})
  end

  operation(:confirm_user,
    operation_id: "confirmUser",
    summary: "Confirm a user's account",
    description:
      "The relation an admin writes in place of the emailed token: admin--confirms--user. " <>
        "Without a mail server attached, registration leaves an account unconfirmed and this is how it is confirmed.",
    parameters: [id: [in: :path, schema: %Schema{type: :string, format: :uuid}]],
    responses: [
      ok: {"", "application/json", %Schema{type: :object}},
      not_found: {"", "application/json", %Schema{type: :object}}
    ]
  )

  def confirm_user(conn, %{"id" => id}) do
    case Uro.Accounts.get_user!(id) do
      %Uro.Accounts.User{} = user ->
        user =
          user
          |> Ecto.Changeset.change()
          |> Uro.Accounts.User.confirm_email_changeset()
          |> Uro.Repo.update!()

        json(conn, %{data: %{user: Uro.Accounts.User.to_json_schema(user, conn)}})

      _ ->
        {:error, :not_found}
    end
  end
end

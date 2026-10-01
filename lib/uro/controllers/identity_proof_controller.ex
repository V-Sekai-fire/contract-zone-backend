# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.IdentityProofController do
  use Uro, :controller

  alias Uro.Error

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, %{"identity_proof" => identity_proof_params}) do
    if Map.has_key?(identity_proof_params, "user_to") do
      user_from = conn.assigns[:current_user]
      user_to = Uro.Accounts.get_user!(Map.get(identity_proof_params, "user_to"))

      if user_to do
        user_from
        |> Uro.UserRelations.create_identity_proof(user_to)
        |> case do
          {:ok, identity_proof} ->
            json(conn, %{id: identity_proof.id})

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = Ecto.Changeset.traverse_errors(changeset, &Error.translate/1)

            conn
            |> put_status(500)
            |> json(%{
              error: %{status: 500, message: "Couldn't create identity_proof", errors: errors}
            })
        end
      else
        conn
        |> put_status(500)
        |> json(%{error: %{status: 500, message: "Recipiant id invalid"}})
      end
    else
      conn
      |> put_status(500)
      |> json(%{error: %{status: 500, message: "No recipiant for identity_proof"}})
    end
  end

  def show(conn, %{"id" => id}) do
    id
    |> Uro.UserRelations.get_identity_proof_as!(conn.assigns[:current_user])
    |> case do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: %{status: 404, message: "No such identity proof"}})

      identity_proof ->
        alias Uro.Accounts.User

        json(conn, %{
          data: %{
            identity_proof: %{
              id: identity_proof.id,
              user_from: User.to_limited_json_schema(identity_proof.user_from),
              user_to: User.to_limited_json_schema(identity_proof.user_to)
            }
          }
        })
    end
  end
end

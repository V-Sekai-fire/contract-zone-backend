# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """

  use Uro, :controller

  alias Ecto.Changeset
  alias Uro.Error

  def call(conn, errors) when is_list(errors) do
    json_error(
      conn,
      code: :bad_request,
      properties:
        errors
        |> Enum.map(fn %{path: path} = error ->
          {Enum.join(path, "."), OpenApiSpex.Cast.Error.message(error)}
        end)
        |> Map.new()
    )
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    properties = Changeset.traverse_errors(changeset, &Error.translate/1)

    json_error(
      conn,
      code: :bad_request,
      properties: properties
    )
  end

  # Used by: Pow.Plug.RequireAuthenticated.
  def call(conn, :not_authenticated), do: call(conn, {:error, :invalid_credentials})

  def call(conn, {:error, :invalid_credentials}) do
    json_error(conn, code: :unauthorized, message: "Invalid credentials")
  end

  def call(conn, {:error, :insufficient_permission}) do
    json_error(conn, code: :forbidden, message: "Insufficient permission")
  end

  def call(conn, {:error, :registration_closed}) do
    json_error(conn, code: :forbidden, message: "Registration is closed")
  end

  def call(conn, {:error, :second_factor_required}) do
    json_error(conn, code: :unauthorized, message: "Second factor required")
  end

  def call(conn, {:error, :invalid_passkey}) do
    json_error(conn, code: :unauthorized, message: "Invalid passkey")
  end

  def call(conn, {:error, :invalid_second_factor}) do
    json_error(conn, code: :unauthorized, message: "Invalid second factor")
  end

  def call(conn, {:error, reason})
      when reason in [:no_enrollment, :already_enabled, :not_enabled] do
    message =
      %{
        no_enrollment: "No authenticator enrolment to confirm",
        already_enabled: "An authenticator is already enabled",
        not_enabled: "No authenticator is enabled"
      }[reason]

    json_error(conn, code: :conflict, message: message)
  end

  def call(conn, {:error, :account_locked}) do
    json_error(conn, code: :locked, message: "Account unavailable")
  end

  def call(conn, {:error, status}) when is_atom(status) do
    json_error(conn, code: status)
  end

  def call(conn, {:error, status, message}) when is_atom(status) and is_binary(message) do
    json_error(conn, code: status, message: message)
  end

  def call(conn, _), do: json_error(conn, code: :internal_server_error)
end

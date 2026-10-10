# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Lobby.Server do
  @moduledoc "One listed game server: a Basis server or an Overte domain."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [inserted_at: :created_at, type: :utc_datetime]

  @platforms ~w(basis overte)
  @statuses ~w(unknown up down)

  schema "lobby_servers" do
    field(:platform, :string)
    field(:external_id, :string)
    field(:address, :string)
    field(:name, :string)
    field(:motd, :string)
    field(:online, :integer)
    field(:capacity, :integer)
    field(:status, :string, default: "unknown")
    field(:client_url, :string)
    field(:last_polled_at, :utc_datetime)
    field(:last_seen_at, :utc_datetime)

    timestamps()
  end

  @fields ~w(platform external_id address name motd online capacity status client_url last_polled_at last_seen_at)a

  def changeset(server, attrs) do
    server
    |> cast(attrs, @fields)
    |> validate_required([:platform, :external_id, :address, :name])
    |> validate_inclusion(:platform, @platforms)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:name, max: 128)
    |> validate_length(:motd, max: 512)
    |> unique_constraint([:platform, :external_id])
  end
end

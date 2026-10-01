# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Repo.WeftFdb do
  @moduledoc """
  Registers datasource-store's `weft_fdb` SQLite VFS in this BEAM so Uro.Repo can open
  `file:<name>?vfs=weft_fdb`, whose pages live in FoundationDB. The weftfdb extension is
  loaded once, on a throwaway in-memory connection, and stays registered for the process.
  """

  @doc "Loads the configured extension once per BEAM; `:loaded` when one is configured."
  def load_configured! do
    case Application.get_env(:uro, :weftfdb_extension) do
      nil ->
        :none

      path ->
        unless :persistent_term.get({__MODULE__, path}, false) do
          :ok = load!(path)
          :persistent_term.put({__MODULE__, path}, true)
        end

        :loaded
    end
  end

  def load!(path) do
    {:ok, conn} = Exqlite.Sqlite3.open(":memory:")

    try do
      :ok = Exqlite.Sqlite3.enable_load_extension(conn, true)

      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "SELECT load_extension('#{String.replace(path, "'", "''")}')"
        )
    after
      Exqlite.Sqlite3.close(conn)
    end
  end
end

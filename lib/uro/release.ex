# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Release do
  @moduledoc """
  Migration entry point for the compiled release.

  A real OTP release (what `mix release` + Burrito produce) has no
  `mix` tasks available at runtime -- `mix ecto.migrate` does not exist
  inside the release, only in a `mix`-based dev checkout. This is the
  standard Phoenix release pattern: run migrations via `Ecto.Migrator`
  directly, invoked through `bin/uro eval "Uro.Release.migrate()"`
  (or, self-contained, through this app's own boot flow before starting
  the endpoint).

  Migrates through `Uro.Repo` itself, before the endpoint starts: a weft_fdb
  database admits one connection, since every open takes its fence.
  """

  @app :uro

  def migrate do
    load_app()
    Uro.Repo.WeftFdb.load_configured!()

    for repo <- [Uro.Repo] do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp load_app do
    Application.load(@app)
  end
end

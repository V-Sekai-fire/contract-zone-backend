# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.MixProject do
  use Mix.Project

  def project do
    [
      app: :uro,
      version: "0.1.0",
      elixir: ">= 1.16.3",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:elixir_make] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      releases: releases()
    ] ++ make_options()
  end

  # Burrito wraps the real OTP release `mix release` produces into a
  # single self-contained executable (bundled ERTS + BEAM files),
  # cross-compiled via Zig -- no target-matching Erlang install needed
  # on the machine that runs it, only on the machine that builds it.
  # linux musl x86_64 matches Fly's own runner (Alpine-based images
  # elsewhere in this repo, e.g. the root Dockerfile's `elixir:*-alpine`
  # base), avoiding a glibc/musl mismatch between build and run images.
  defp releases do
    [
      uro: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_musl: [os: :linux, cpu: :x86_64, libc: :musl]
          ]
        ]
      ]
    ]
  end

  # `mix dialyzer` (dialyxir). PLTs are cached under `priv/plts` (not
  # `_build`) so a `mix clean`/fresh `_build` doesn't force a full PLT
  # rebuild -- that's the slow part (core Erlang/Elixir PLT), not
  # incremental analysis of this app's own modules.
  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :ex_unit],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  # weft_warp_burrito's sandbox NIF (lib/weft_warp_burrito/*,
  # c_src/{guest,nif,thirdparty}) was extracted directly into this app -- a
  # single root Makefile builds it. mingw32-make on Windows (matches
  # weft_warp_burrito's own former mix.exs -- its CMake+Ninja+RISC-V recipe
  # was only ever GNU Make syntax, no MSVC/nmake port exists for it). The
  # taskweft_nif.cpp/standalone/ native planner+ReBAC NIF this Makefile used
  # to also build was retired in RFD 0038, once the compiled-Scheme sandbox
  # adapters (RFD 0022/0023) became the only ReBAC/planner adapters; those
  # were themselves retired in favor of plain-Elixir ports (RFD 0039), which
  # is why c_src/s7 (the in-repo s7 AOT compiler this comment used to
  # mention) no longer exists either.
  defp make_options do
    base = [make_env: fn -> %{"FINE_INCLUDE_DIR" => Fine.include_dir()} end]

    case :os.type() do
      {:win32, _} -> base ++ [make_executable: "mingw32-make"]
      _ -> base
    end
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Uro.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :email_checker,
        :mnesia,
        :scrivener_ecto,
        :httpoison,
        :opentelemetry_exporter,
        :opentelemetry
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    common_deps()
  end

  defp common_deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.0"},
      {:phoenix_ecto, "~> 4.4"},
      {:phoenix_live_view, "~> 0.20.3"},
      {:phoenix_view, "~> 2.0"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.17"},
      {:phoenix_html, "~> 3.3"},
      {:cors_plug, "~> 3.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:gettext, "~> 0.18"},
      {:httpoison, "~> 2.0"},
      {:jason, "~> 1.2"},
      {:joken, "~> 2.6"},
      {:bandit, "~> 1.0"},
      {:plug_static_index_html, "~> 1.0"},
      {:comeonin, "~> 5.3.2"},
      {:bcrypt_elixir, "~> 2.3"},
      {:nimble_totp, "~> 1.0"},
      {:pow, "~> 1.0"},
      {:email_checker, "~> 0.1.4"},
      {:pow_assent, "~> 0.4.18"},
      {:ssl_verify_fun, "~> 1.1.6"},
      {:open_api_spex, "~> 3.21"},
      {:ex_json_schema, "~> 0.10"},
      {:remote_ip, "~> 1.0"},
      {:waffle, "~> 1.1"},
      {:waffle_ecto, "~> 0.0.10"},
      {:ecto_commons, "~> 0.3.4"},
      {:swoosh, "~> 1.3"},
      {:hammer, "~> 6.0"},
      {:scrivener_ecto, "~> 3.1"},
      {:ex_marcel, "~> 0.1.0"},
      {:elixir_make, "~> 0.10", runtime: false},
      {:fine, "~> 0.1", runtime: false},
      {:burrito, "~> 1.0"},
      {:aria_storage, github: "V-Sekai-fire/aria-storage"},
      {:uro_loop, path: "apps/uro_loop"},
      {:mox, "~> 1.1", only: :test},

      # OpenTelemetry — ships spans + logs to multiplayer-fabric-observability
      {:opentelemetry, "~> 1.6"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.9"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_ecto, "~> 1.2"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to create, migrate and run the seeds file at once:
  #
  #     $ mix ecto.setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "uro.apigen": [
        "openapi.spec.json --spec Uro.OpenAPI.Specification --pretty --vendor-extensions=false ./frontend/src/__generated/openapi.json"
      ],

      # Not required, fixes warning https://github.com/chaskiq/ex-marcel/pull/2
      "patch.exmarcel": fn _args ->
        path = "deps/ex_marcel/lib/magic.ex"

        patched =
          String.replace(
            File.read!(path),
            "ext |> String.slice(1..-1)",
            "ext |> String.slice(1..-1//1)"
          )

        File.write!(path, patched)
        IO.puts("Module 'ex_marcel' patched successfully!")
      end,
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end
end

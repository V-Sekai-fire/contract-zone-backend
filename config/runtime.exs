# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
import Config
require Logger

# Real Phoenix runtime config: evaluated once, at boot, inside the
# compiled OTP release Burrito wraps (mix.exs's releases: block) -- not
# at `mix compile` time. This replaces config.exs's former COMPILE_PHASE
# trick (Uro.Config.Helpers.get_env/2), which existed only because this
# app used to boot via `iex -S mix ...` instead of a real release: `mix`
# re-evaluates config.exs on every invocation, so that trick let the
# Docker *build* step run with no real secrets present (COMPILE_PHASE=
# true, return the placeholder), then have the container's actual boot
# command re-run `mix` a second time with COMPILE_PHASE=false and real
# secrets in the environment. A real OTP release only ever evaluates
# config.exs/prod.exs once, at build time, permanently -- there is no
# second pass at boot -- so anything that needs a real deploy-time
# secret has to live here instead, in config/runtime.exs, which the
# release genuinely does re-evaluate every time it starts.
#
# Only :prod is gated below; dev.exs/test.exs already define their own
# complete, static Uro.Repo config and never build a release.
if config_env() == :prod do
  url =
    "URL"
    |> System.fetch_env!()
    |> URI.new!()

  root_origin =
    "ROOT_ORIGIN"
    |> System.fetch_env!()
    |> URI.new!()

  config :uro,
    url: url,
    frontend_url:
      "FRONTEND_URL"
      |> System.fetch_env!()
      |> URI.new!(),
    root_origin: root_origin

  config :uro, :weftfdb_extension, System.fetch_env!("URO_WEFTFDB_EXTENSION")

  # Passkeys bind to this origin's host, so it must not change once users have registered.
  config :uro, :webauthn,
    origin: System.get_env("WEBAUTHN_ORIGIN", URI.to_string(root_origin)),
    rp_id: System.get_env("WEBAUTHN_RP_ID", root_origin.host)

  # One connection: every open of a weft_fdb database takes its fence (datasource-store).
  config :uro, Uro.Repo,
    database: System.get_env("URO_DATABASE", "file:uro.v1?vfs=weft_fdb"),
    pool_size: 1,
    journal_mode: :memory,
    locking_mode: :exclusive,
    migration_lock: false

  https_port = String.to_integer(System.get_env("HTTPS_PORT") || "443")
  http_port = String.to_integer(System.get_env("PORT") || "4000")

  https_opts =
    case {System.get_env("HTTPS_CERTFILE"), System.get_env("HTTPS_KEYFILE")} do
      {cert, key} when is_binary(cert) and is_binary(key) ->
        [https: [port: https_port, certfile: cert, keyfile: key]]

      _ ->
        []
    end

  config :uro,
         Uro.Endpoint,
         [
           {:adapter, Bandit.PhoenixAdapter},
           {:url, Map.take(url, [:scheme, :host, :path])},
           {:http, [port: http_port]},
           {:server, true},
           {:secret_key_base, System.fetch_env!("PHOENIX_KEY_BASE")}
         ] ++ https_opts

  config :cors_plug,
    origin: [URI.to_string(root_origin)],
    max_age: 86400

  config :joken, default_signer: System.fetch_env!("JOKEN_SIGNER")

  config :uro, Uro.Turnstile,
    secret_key:
      System.get_env("TURNSTILE_SECRET_KEY") ||
        Logger.warning(
          "Turnstile (a reCaptcha alternative) is disabled because the environment " <>
            "variable TURNSTILE_SECRET_KEY is not set. See " <>
            "https://developers.cloudflare.com/turnstile/get-started/."
        )

  config :uro, :registration_open, System.get_env("URO_REGISTRATION_OPEN") == "true"

  # Sign-in providers: Discord, GitHub and Google, each enabled by its client id.
  config :uro, :pow_assent,
    providers:
      [
        discord: Assent.Strategy.Discord,
        github: Assent.Strategy.Github,
        google: Assent.Strategy.Google
      ]
      |> Enum.flat_map(fn {name, strategy} ->
        key = name |> Atom.to_string() |> String.upcase()

        case System.get_env("OAUTH2_#{key}_CLIENT_ID") do
          nil ->
            []

          client_id ->
            [
              {name,
               [
                 client_id: client_id,
                 client_secret: System.fetch_env!("OAUTH2_#{key}_CLIENT_SECRET"),
                 strategy: strategy
               ]}
            ]
        end
      end)

  config :uro, Uro.Mailer,
    adapter: Swoosh.Adapters.Sendgrid,
    api_key: System.get_env("SENDGRID_API_KEY", "")

  config :ex_aws,
    access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}],
    secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}]

  config :ex_aws, :s3,
    scheme: "http://",
    host: System.get_env("VERSITYGW_HOST", "versitygw"),
    port: String.to_integer(System.get_env("VERSITYGW_PORT", "7070"))

  otel_endpoint =
    System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") ||
      "http://multiplayer-fabric-observability.internal:4318"

  config :opentelemetry,
    span_processor: :batch,
    traces_exporter: :otlp,
    resource: %{
      "service.name" => "multiplayer-fabric-uro",
      "service.version" => to_string(Application.spec(:uro, :vsn) || "0.0.0"),
      "deployment.environment" => "fly-iad"
    }

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: otel_endpoint

  config :aria_storage, :waffle_bucket, System.get_env("CHUNK_BUCKET", "zone-chunks")

  config :aria_storage, AriaStorage.Repo,
    database: System.get_env("ARIA_STORAGE_DB", "/app/priv/aria_storage.db")
end

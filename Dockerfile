ARG ELIXIR_VERSION=1.17

# Elixir build environment.
FROM elixir:${ELIXIR_VERSION}-alpine AS elixir-base

ARG MIX_ENV=prod

ENV MIX_ENV=${MIX_ENV} \
	COMPILE_PHASE=true

WORKDIR /app

RUN apk add --no-cache \
	nodejs \
	npm \
	inotify-tools \
	git \
	bash \
	make \
	gcc \
	g++ \
	curl \
	libc-dev \
	cmake \
	ninja

RUN mix local.hex --force && \
	mix local.rebar --force

# apps/uro_loop is a `path:` dependency, so its mix.exs has to be present
# before `deps.get` -- mix resolves path deps by reading them in place.
COPY mix.exs mix.lock ./
COPY apps ./apps
RUN mix do deps.get, patch.exmarcel, deps.compile

COPY config ./config
COPY priv ./priv
COPY lib ./lib
COPY scripts ./scripts

# The :elixir_make compiler runs the root Makefile during `mix compile`,
# which cmake-builds the weft_sandbox_nif (libriscv) shared object.
COPY Makefile ./
COPY c_src ./c_src

RUN mix do compile, phx.digest

# `mix uro.apigen` is deliberately NOT run here. It boots the app
# (app.start), so config/runtime.exs's :prod branch demands real
# deploy-time secrets (URL, URO_WEFTFDB_EXTENSION, PHOENIX_KEY_BASE, ...) that
# no image build has. Its only output is
# frontend/src/__generated/openapi.json -- an input to the separate
# nextjs service's build (frontend/openapi-ts.config.ts), which this
# backend-only image neither copies nor serves. Generate it from the
# frontend's own build instead.

EXPOSE ${PORT}

ENV COMPILE_PHASE=false
ENTRYPOINT iex -S mix do ecto.create, ecto.migrate, run priv/repo/test_seeds.exs, phx.server

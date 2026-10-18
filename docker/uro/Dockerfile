# Real production image for multiplayer-fabric-uro: a Burrito-wrapped
# OTP release, not the root Dockerfile's dev-shaped `iex -S mix do
# ecto.create, ecto.migrate, run priv/repo/test_seeds.exs, phx.server`
# (which seeds dummy test data on every boot -- fine for local
# docker-compose, wrong for a real deploy).
#
# Burrito (mix.exs's releases: block) wraps a real `mix release` into
# one self-contained, statically-linked executable (musl libc, bundled
# ERTS), cross-compiled via Zig. Verified locally before this Dockerfile
# was written: `mix release uro` produces burrito_out/uro_linux_musl, a
# real ELF 64-bit static binary, and `PORT=4999 ./uro_linux_musl start`
# genuinely boots Uro.Endpoint with Bandit and serves, using
# config/runtime.exs (not config.exs's old COMPILE_PHASE trick) for every
# deploy-time secret. Because the binary is fully static, the runtime
# stage below needs nothing but the binary itself and CA certs for
# outbound TLS (S3-compatible storage, OTLP).
#
# Migrations run via Uro.Release.migrate/0 (lib/uro/release.ex),
# through Uro.Repo, standard Phoenix-release
# pattern -- `mix ecto.migrate` does not exist inside a compiled release.
# Elixir 1.17 to match .github/workflows/ci.yml. 1.16 mis-parses
# `@fixnum_min -(1 <<< 60)` (lib/weft_warp_burrito/program.ex) as a
# read-and-subtract rather than an attribute definition, so this must
# stay >= 1.17.
FROM elixir:1.17-alpine AS build

RUN apk add --no-cache \
	nodejs npm inotify-tools git bash make gcc g++ curl libc-dev \
	cmake ninja xz

# Burrito 1.6.0 pins an exact Zig version (0.16.0) and refuses to run on
# anything else; Alpine's `zig` package is 0.14.1, so install upstream's
# static build instead.
ARG ZIG_VERSION=0.16.0
RUN curl -fsSL -o /tmp/zig.tar.xz \
		https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz \
	&& mkdir -p /opt/zig \
	&& tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
	&& rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"

# xpack riscv-none-elf-gcc: needed by the c_src NIF build
# (WeftWarpBurrito.SandboxNif's guest target), same toolchain
# .github/workflows/casync-interop.yml already installs for CI.
RUN curl -fsSL -o /tmp/riscv-gcc.tar.gz \
		https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz \
	&& mkdir -p /opt/riscv-none-elf-gcc \
	&& tar -xzf /tmp/riscv-gcc.tar.gz -C /opt/riscv-none-elf-gcc --strip-components=1 \
	&& rm /tmp/riscv-gcc.tar.gz
ENV PATH="/opt/riscv-none-elf-gcc/bin:${PATH}"

ENV MIX_ENV=prod
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# apps/uro_loop is a `path:` dependency, so its mix.exs has to be present
# before `deps.get` -- mix resolves path deps by reading them in place.
COPY mix.exs mix.lock ./
COPY apps ./apps
RUN mix do deps.get, patch.exmarcel, deps.compile

COPY config ./config
COPY priv ./priv
COPY lib ./lib

# The :elixir_make compiler runs the root Makefile during the release
# build, which cmake-builds the weft_sandbox_nif (libriscv) shared object.
COPY Makefile ./
COPY c_src ./c_src

RUN mix release uro

# Runtime stage: the release is a fully static musl binary, so this
# only needs CA certs for outbound TLS, not an Elixir/Erlang install.
FROM alpine:3.20 AS runtime
RUN apk add --no-cache ca-certificates
COPY --from=build /app/burrito_out/uro_linux_musl /usr/local/bin/uro
COPY docker/uro/fly-start.sh /usr/local/bin/fly-start.sh
RUN chmod +x /usr/local/bin/fly-start.sh

EXPOSE 4000
ENTRYPOINT ["/usr/local/bin/fly-start.sh"]

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro do
  @moduledoc """
  Multiplayer Fabric zone backend (Uro) — Phoenix/Elixir API server.

  ## Service topology

  ```
  Internet
    │
    ▼
  Cloudflare edge  (orange cloud ON, Full strict SSL)
    │  hub-700a.chibifire.com  DNS A → 173.180.240.105
    ▼
  Caddy:443  (Cloudflare Origin Certificate)
    │  /api/v1/*   → uro:4000   (prefix stripped before proxying)
    │  /uploads/*  → uro:4000
    │  /*          → frontend:3000  (Next.js web UI; not required for PoC)
    ▼
  uro:4000  (this application, Phoenix/Bandit)
    ├── uro.v1            SQLite in-process on the weft_fdb VFS, pages in FoundationDB
    └── versitygw:7070    VersityGW S3-compatible object store (POSIX backend)

  zone-700a.chibifire.com
    │  DNS A record → 173.180.240.105  (orange cloud OFF — Cloudflare cannot proxy UDP)
    │  Router forwards UDP 7443–7542 → host machine
    ▼
  zone-server:7443–7542/udp  (Godot headless, editor=no, up to 100 concurrent zones)
    └── WebTransport / QUIC / picoquic
  ```

  ## Key design decisions

  ### Cloudflare Origin Certificate for HTTP, direct UDP for WebTransport

  HTTP traffic is proxied by Cloudflare (Full strict mode). Caddy holds a
  Cloudflare Origin Certificate. WebTransport uses QUIC over UDP; Cloudflare
  cannot proxy UDP, so the zone server hostname (`zone-700a.chibifire.com`) is
  DNS-only (orange cloud off). Clients pin the zone server's self-signed cert
  using `cert_hash` from `GET /shards`.

  ### Zone authority and interest management

  The zone whose Hilbert curve range contains `hilbert3D(pos)` is authoritative
  for any entity at that position. Only the authority zone executes
  `CMD_INSTANCE_ASSET`. Neighbouring zones within `AOI_CELLS` receive a
  `CH_INTEREST` ghost without re-fetching. All Hilbert curve and BVH invariants
  are formally proved in `multiplayer-fabric-predictive-bvh`.

  ### ReBAC access control

  The authority zone evaluates ReBAC permissions before instancing. `observe`
  is public; `modify` requires `owner`. Policies are stored in CockroachDB and
  evaluated by the zone server C++ module.

  ### Headless asset baking

  Zone servers use an `editor=no` Godot build. Asset validation and casync
  chunking run in a separate one-shot baker container (`editor=yes`). See
  `Uro.StorageController` for the full pipeline.

  ### Wire-compat: /shards path

  The HTTP endpoints are named `/shards` (not `/zones`) to maintain
  backward compatibility with deployed zone server clients. The DB table and
  internal modules use `zone` terminology.

  ## Data model

  ```
  users
    id (uuid)  email  username  display_name

  user_identities
    provider ("pow_assent" | …)  uid  → users

  shared_files
    id (uuid)  name  tags[]  is_public
    store_url     raw upload location (VersityGW)
    chunks        [{hash, offset, length}] jsonb
    baked_url     .caidx index URL (set after baker completes)
    uploader_id → users

  zones
    id (uuid)  address  port  map  name
    current_users  max_users
    cert_hash     SHA-256 fingerprint of zone server TLS cert (base64)
    last_put_at   set by each explicit PUT /shards/:id from the zone server process
  ```

  ## Using this module

  Controllers, views, and channels call `use Uro, :controller` (etc.) to pull
  in standard imports:

      use Uro, :controller
      use Uro, :view
  """

  def mailer_view do
    quote do
      use Phoenix.View,
        root: "lib/uro_web/templates",
        namespace: Uro

      use Phoenix.HTML
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, namespace: Uro
      use Uro.Helpers.API
      use OpenApiSpex.ControllerSpecs

      import Plug.Conn
      import Uro.Gettext
      import Uro.Helpers.User

      # alias Uro.Router.Helpers, as: Routes
    end
  end

  def view do
    quote do
      use Phoenix.View,
        root: "lib/uro_web/templates",
        namespace: Uro

      # Import convenience functions from controllers
      import Phoenix.Controller, only: [get_flash: 1, get_flash: 2, view_module: 1]

      # Use all HTML functionality (forms, tags, etc)
      use Phoenix.HTML

      import Uro.ErrorHelpers
      import Uro.Gettext
      # alias Uro.Router.Helpers, as: Routes
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
      import Uro.Gettext
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.ZoneController do
  @moduledoc """
  HTTP handlers for zone registration and discovery.

  A **zone** is a running WebTransport game server
  (`zone-700a.chibifire.com:7443`). Zone servers self-register via
  `POST /shards` on boot and keep themselves alive with `PUT /shards/:id`
  heartbeats every ~25 s. `ZoneJanitor` culls entries whose `last_put_at` falls
  outside the configured staleness window.

  ## Self-registration flow

  ```
  zone server boots
    → POST /shards  {address, port, map, name, cert_hash}
    → zone-backend writes row to zones table

  every ~25 s:
    → PUT /shards/:id   (sets last_put_at — acts as heartbeat)

  ZoneJanitor (GenServer)
    → runs every :stale_zone_interval ms
    → deletes rows where last_put_at < now - :stale_zone_cutoff
  ```

  ## cert_hash

  `cert_hash` is the base64-encoded SHA-256 fingerprint of the zone server's
  self-signed TLS certificate. Clients pin this value when opening a
  WebTransport connection; no CA chain is needed. See the `x-webtransport`
  extension on `GET /shards` for the full connection and wire-protocol spec.

  ## Cloudflare DNS requirement

  Zone server hostnames currently use DNS-only (orange cloud disabled) because
  the standard Cloudflare proxy cannot forward QUIC/UDP. Cloudflare's
  MASQUE-based proxy mode (2025) may pass UDP datagrams transparently;
  compatibility with zone server QUIC traffic is under evaluation. Until that
  test completes, the A record must point directly to the host machine.

  ```sh
  # Verify DNS is not proxied
  dig zone-700a.chibifire.com +short   # expect: 173.180.240.105

  # Confirm UDP 7443 reachable
  nc -u -w2 zone-700a.chibifire.com 7443 && echo "UDP open"
  ```

  ## Source files

  | File | Role |
  |------|------|
  | `lib/uro/v_sekai/zone.ex` | Ecto schema, changeset, `to_json_schema/1` |
  | `lib/uro/v_sekai/zone_janitor.ex` | GenServer that culls stale zones |
  | `lib/uro/v_sekai.ex` | Context: `list_fresh_zones`, CRUD |
  | `lib/uro/controllers/zone.ex` | HTTP handlers (this file) |
  """

  use Uro, :controller

  alias OpenApiSpex.Schema
  alias Uro.Repo
  alias Uro.VSekai
  alias Uro.VSekai.Zone

  tags(["zones"])

  def ensure_has_address(conn, params) do
    if Map.has_key?(params, "address") do
      params
    else
      Map.put(params, "address", to_string(:inet_parse.ntoa(conn.remote_ip)))
    end
  end

  def ensure_user_is_current_user_or_nil(conn, params) do
    if Uro.Helpers.Auth.signed_in?(conn) do
      Map.put(params, "user_id", Uro.Helpers.Auth.get_current_user(conn).id)
    else
      Map.put(params, "user_id", nil)
    end
  end

  def can_connection_modify_zone(conn, zone) do
    if zone.user != nil and
         Uro.Helpers.Auth.signed_in?(conn) and
         zone.user == Uro.Helpers.Auth.get_current_user(conn) do
      true
    else
      if zone.user == nil and
           zone.address == to_string(:inet_parse.ntoa(conn.remote_ip)) do
        true
      else
        false
      end
    end
  end

  @webtransport_extension %{
    "description" =>
      "After obtaining a zone record from GET /shards, clients open a WebTransport session directly to the zone server. The zone-backend HTTP API is not involved in the live session.",
    "connection" => %{
      "url_template" => "https://{address}:{port}",
      "transport" => "QUIC/HTTP3 (WebTransport)",
      "port_pool" =>
        "UDP 7443–7542; orchestrator assigns one port per zone instance (up to 100 concurrent zones)",
      "cert_pin" => %{
        "source_field" => "cert_hash",
        "encoding" => "base64url",
        "algorithm" => "SHA-256",
        "description" =>
          "Self-signed TLS certificate fingerprint from the zone record. Clients pin this value; no CA chain is required. Supplied by the zone server at registration time."
      },
      "dns_requirement" =>
        "zone-700a.chibifire.com must use DNS-only (Cloudflare orange cloud OFF). QUIC/UDP cannot be proxied. The A record must point directly to the host machine (173.180.240.105)."
    },
    "commands" => [
      %{
        "name" => "CMD_INSTANCE_ASSET",
        "opcode" => "0x04",
        "description" =>
          "Instance a baked asset at a world position. Send this after the asset's baked_url is set (poll POST /storage/:id/manifest until baked_url is non-null). The authority zone (hilbert3D(pos)) fetches the .caidx, reassembles the .scn from casync chunks, and creates the entity. Neighbouring zones within AOI_CELLS receive a CH_INTEREST ghost without re-fetching.",
        "access_control" => %{
          "model" => "ReBAC",
          "observe" => "public — all connected clients receive entity snapshots",
          "modify" => "owner only — only the uploader may instance their own asset",
          "storage" =>
            "Uro.Repo (SQLite on FoundationDB); evaluated by the zone server C++ module"
        },
        "packet" => %{
          "total_bytes" => 100,
          "encoding" => "binary, little-endian",
          "fields" => [
            %{
              "offset" => 0,
              "size" => 2,
              "type" => "uint16",
              "name" => "opcode",
              "notes" => "low byte == 0x04 (CMD_INSTANCE_ASSET); high byte reserved, set to 0"
            },
            %{
              "offset" => 2,
              "size" => 4,
              "type" => "uint32",
              "name" => "asset_id",
              "notes" =>
                "lower 32 bits of the asset UUID returned by POST /storage; used by the zone server to look up the .caidx in VersityGW"
            },
            %{
              "offset" => 6,
              "size" => 4,
              "type" => "float32",
              "name" => "cx",
              "notes" => "world position x, metres; determines Hilbert authority zone"
            },
            %{
              "offset" => 10,
              "size" => 4,
              "type" => "float32",
              "name" => "cy",
              "notes" => "world position y, metres"
            },
            %{
              "offset" => 14,
              "size" => 4,
              "type" => "float32",
              "name" => "cz",
              "notes" => "world position z, metres"
            },
            %{
              "offset" => 18,
              "size" => 82,
              "type" => "bytes",
              "name" => "reserved",
              "notes" => "zero padding; total packet size is always exactly 100 bytes"
            }
          ],
          "source" =>
            "multiplayer-fabric-zone-console/lib/zone_console/zone_client.ex — encode_instance/8",
          "tests" =>
            "multiplayer-fabric-zone-console/test/zone_console/zone_client_encoding_test.exs — PropCheck properties verify: (1) packet is exactly 100 bytes, (2) opcode low byte equals 4, (3) asset_id round-trips through encode/decode, (4) position round-trips as float32"
        }
      }
    ],
    "authority_model" => %{
      "algorithm" => "hilbert3D(pos)",
      "description" =>
        "The zone whose Hilbert curve range contains hilbert3D(pos) is authoritative for any entity at that position. Authority is the only zone that executes CMD_INSTANCE_ASSET. The 3D Hilbert curve is formally proved in multiplayer-fabric-predictive-bvh/PredictiveBVH.lean.",
      "interest_management" =>
        "Neighbouring zones within AOI_CELLS receive a CH_INTEREST ghost — they do not re-fetch or re-instance. Interest management bounds are proved in multiplayer-fabric-predictive-bvh."
    },
    "server_responses" => [
      %{
        "name" => "entity_snapshot",
        "trigger" =>
          "Zone server sends the current entity list to a client immediately after CMD_INSTANCE_ASSET is processed, and on initial connect.",
        "fields" => [
          %{
            "name" => "id",
            "type" => "integer",
            "description" => "Entity ID assigned by the zone server"
          },
          %{
            "name" => "pos",
            "type" => "object {x, y, z}",
            "description" => "float32 world position in metres"
          },
          %{
            "name" => "type",
            "type" => "string",
            "description" => "\"scene\" for asset instances"
          },
          %{
            "name" => "asset_id",
            "type" => "string",
            "description" => "UUID matching the asset_id field sent in CMD_INSTANCE_ASSET"
          }
        ]
      }
    ],
    "elixir_client" => %{
      "module" => "ZoneConsole.ZoneClient (multiplayer-fabric-zone-console)",
      "example" => """
      {:ok, zc} = ZoneConsole.ZoneClient.start_link(url, cert_pin, zone_id, self())
      ZoneConsole.ZoneClient.send_instance(zc, asset_id, cx, cy, cz)
      receive do
        {:zone_entities, entities} -> IO.inspect(entities)
      end
      ZoneConsole.ZoneClient.stop(zc)
      """
    }
  }

  operation(:index,
    operation_id: "listZones",
    summary: "List Zones",
    description: """
    Returns all zone servers that have sent a heartbeat within the last 30 seconds.

    Each record contains `address`, `port`, and `cert_hash`. Use these to open
    a WebTransport session directly to the zone server — see the
    `x-webtransport` extension for the complete connection procedure and
    `CMD_INSTANCE_ASSET` wire-protocol specification.
    """,
    "x-webtransport": @webtransport_extension,
    responses: [
      ok: {
        "",
        "application/json",
        %Schema{
          type: :array,
          items: Zone.json_schema()
        }
      }
    ]
  )

  def index(conn, _params) do
    zones = VSekai.list_fresh_zones()
    zones_json = Enum.map(zones, fn x -> Zone.to_json_schema(x) end)

    conn
    |> put_status(200)
    |> json(%{data: %{shards: zones_json}})
  end

  operation(:create,
    operation_id: "createZone",
    summary: "Create Zone",
    description: """
    Called by a zone server on boot to register itself. Writes a row to the
    `zones` table. If `address` is omitted, zone-backend fills it from the
    request's remote IP.

    After registration the zone server must send `PUT /shards/:id` heartbeats
    every ~25 s to stay in the active list returned by `GET /shards`.
    """,
    request_body: {
      "",
      "application/json",
      Zone.json_schema()
    },
    responses: [
      ok: {
        "",
        "application/json",
        %Schema{
          type: :object,
          required: [:id],
          properties: %{
            id: %Schema{
              type: :string
            }
          }
        }
      }
    ]
  )

  def create(conn, zone_params) do
    zone_params = ensure_has_address(conn, zone_params)

    conn
    |> ensure_user_is_current_user_or_nil(zone_params)
    |> VSekai.create_zone()
    |> case do
      {:ok, zone} ->
        conn
        |> put_status(200)
        |> json(%{data: %{id: to_string(zone.id)}})

      {:error, %Ecto.Changeset{}} ->
        json_error(conn)
    end
  end

  operation(:update,
    operation_id: "updateZone",
    summary: "Update Zone (Heartbeat)",
    description: """
    Zone server heartbeat. Called every ~25 s by the running zone server.
    Sets `last_put_at`; `ZoneJanitor` treats any row whose `last_put_at` is
    older than `:stale_zone_cutoff` as dead and deletes it.

    The request body (`shard` key) is optional — a bare `PUT /shards/:id` with
    no body is valid as a keepalive.
    """,
    parameters: [
      id: [
        in: :path,
        schema: %Schema{
          type: :string
        }
      ]
    ],
    responses: [
      ok: {
        "",
        "application/json",
        Zone.json_schema()
      }
    ]
  )

  def update(conn, %{"id" => id, "shard" => zone_params}) do
    zone = VSekai.get_zone!(id)

    if can_connection_modify_zone(conn, zone) do
      case VSekai.update_zone(zone, zone_params) do
        {:ok, zone} ->
          desync_url = VSekai.get_desync_url_for_map(zone.map)

          # Best-effort broadcast — PubSub may not be running in all envs.
          try do
            Uro.Endpoint.broadcast("zone:#{zone.id}", "zone_updated", %{
              desync_index_url: desync_url
            })
          rescue
            _ -> :ok
          end

          conn
          |> put_status(200)
          |> json(%{data: %{id: to_string(zone.id), desync_index_url: desync_url}})

        {:error, %Ecto.Changeset{}} ->
          json_error(conn)
      end
    else
      json_error(conn)
    end
  end

  def update(conn, %{"id" => id}) do
    update(conn, %{"id" => id, "shard" => %{}})
  end

  operation(:delete,
    operation_id: "deleteZone",
    summary: "Delete Zone",
    description: """
    Remove a zone record. Only the owning user (authenticated) or the originating
    IP address (anonymous zones) may delete the record.
    """,
    parameters: [
      id: [
        in: :path,
        schema: %Schema{
          type: :string
        }
      ]
    ],
    responses: [
      ok: {
        "",
        "application/json",
        success_json_schema()
      }
    ]
  )

  def delete(conn, %{"id" => id}) do
    zone =
      Uro.VSekai.Zone
      |> Repo.get!(id)
      |> Repo.preload(:user)
      |> Repo.preload(user: [:user_privilege_ruleset])

    if can_connection_modify_zone(conn, zone) do
      case VSekai.delete_zone(zone) do
        {:ok, zone} ->
          conn
          |> put_status(200)
          |> json(%{data: %{id: to_string(zone.id)}})

        {:error, %Ecto.Changeset{}} ->
          json_error(conn)
      end
    else
      json_error(conn)
    end
  end
end

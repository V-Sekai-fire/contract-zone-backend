# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.StorageController do
  @moduledoc """
  HTTP handlers for the asset pipeline: upload, bake, manifest, and CRUD.

  ## Pipeline overview

  ```
  1. Client uploads packed scene (.tscn / .scn)
     POST /storage  multipart
     → zone-backend stores raw file in VersityGW
     → writes shared_files row  (store_url set, baked_url null)

  2. zone-backend spawns a one-shot baker container
     docker run --rm multiplayer-fabric-godot-baker:latest
       ASSET_ID=<id>  CONTENT_TYPE=avatar|map
       URO_URL=http://zone-backend:4000
       VERSITYGW_URL=http://versitygw:7070

  3. Baker container (Godot editor=yes build)
     a. Download scene from VersityGW
     b. godot --editor --headless --quit  (resource import pass)
     c. godot --headless --script res://baker/run.gd -- <type> <scene>
          VSKImporter.clean_packed_scene_for_avatar/map/1
          VSKExporter.export_avatar/map/3  →  cleaned binary .scn
     d. AriaStorage.create_chunks(.scn, compression: :zstd)
          → uploads .cacnk chunk files to VersityGW at
            chunks/<ab>/<cd>/<sha512_256>.cacnk
     e. AriaStorage.create_index_from_chunks(chunks, format: :caidx)
          → writes <id>.caidx
     f. POST /storage/<id>/bake  {baked_url: "http://versitygw:7070/.../<id>.caidx"}

  4. zone-backend sets baked_url on the shared_files row

  5. Client polls POST /storage/:id/manifest until baked_url is non-null
     → then sends CMD_INSTANCE_ASSET via WebTransport to the zone server
  ```

  ## casync format

  Assets use the casync content-addressable format (AriaStorage Elixir library):

  - `.cacnk` — content-addressed chunk (SHA512/256 hash, zstd compressed)
  - `.caidx` — directory-tree index referencing chunks by hash + offset
  - Chunk path: `chunks/<first-byte-pair>/<second-byte-pair>/<hash>.cacnk`

  Zone clients download only the chunks they do not already have locally,
  enabling delta-sync updates.

  ## Baker security

  The baker container runs on the Docker-internal network and cannot reach
  the public internet. It authenticates to zone-backend via `BAKER_TOKEN`
  (internal service token), not a user OAuth token.

  ## Monitoring

  ```sh
  # List baker containers (includes exited)
  docker ps -a --filter ancestor=multiplayer-fabric-godot-baker:latest

  # Confirm baked_url set
  bin/uro rpc 'Uro.Repo.query!("SELECT id, name, baked_url IS NOT NULL FROM shared_files ORDER BY created_at DESC LIMIT 5") |> IO.inspect()' 

  # Confirm .caidx present in VersityGW
  AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin \\
    aws --endpoint-url http://localhost:7070 s3 ls s3://uro-uploads/ | grep .caidx
  ```

  ## Source files

  | File | Role |
  |------|------|
  | `lib/uro/controllers/storage.ex` | HTTP handlers (this file) |
  | `lib/uro/shared_content.ex` | Context: DB queries, `set_baked_url` |
  | `lib/uro/shared_content/shared_file.ex` | Ecto schema + changesets |
  | `aria-storage/` | AriaStorage library: casync chunking + index |
  """

  use Uro, :controller

  alias OpenApiSpex.Schema
  alias Uro.SharedContent

  action_fallback Uro.FallbackController

  tags(["storage"])

  operation(:index,
    operation_id: "listSharedFiles",
    summary: "List all public storage files",
    responses: [
      ok: {
        "A successful response returning a list of storage files",
        "application/json",
        %Schema{
          type: :object,
          properties: %{
            data: %Schema{
              type: :object,
              properties: %{
                files: %Schema{
                  type: :array,
                  items: SharedContent.SharedFile.json_schema(),
                  description: "List of files"
                }
              }
            }
          }
        }
      }
    ]
  )

  def index(conn, _params) do
    file_list = SharedContent.list_public_shared_files()

    conn
    |> put_status(200)
    |> json(%{
      data: %{
        files:
          Uro.Helpers.SharedContentHelper.get_api_shared_content_list(file_list, %{
            merge_uploader_id: true
          })
      }
    })
  end

  operation(:index_by_tag,
    operation_id: "listSharedFilesByTag",
    summary: "List all public storage files by tag",
    parameters: [
      OpenApiSpex.Operation.parameter(:tag, :path, :string, "Tag group")
    ],
    responses: [
      ok: {
        "A successful response returning a list of storage files",
        "application/json",
        %Schema{
          type: :object,
          properties: %{
            data: %Schema{
              type: :object,
              properties: %{
                files: %Schema{
                  type: :array,
                  items: SharedContent.SharedFile.json_schema(),
                  description: "List of files"
                }
              }
            }
          }
        }
      }
    ]
  )

  def index_by_tag(conn, %{"tag" => tag}) do
    file_list = SharedContent.list_public_shared_files_by_tag(tag)

    conn
    |> put_status(200)
    |> json(%{
      data: %{
        files:
          Uro.Helpers.SharedContentHelper.get_api_shared_content_list(file_list, %{
            merge_uploader_id: true
          })
      }
    })
  end

  operation(:show,
    operation_id: "getSharedFile",
    summary: "Get File",
    responses: [
      ok: {
        "A successful response returning a single public file",
        "application/json",
        %Schema{
          type: :object,
          properties: %{
            data: %Schema{
              type: :object,
              properties: %{
                files: SharedContent.SharedFile.json_schema()
              }
            }
          }
        }
      }
    ]
  )

  def show(conn, %{"id" => id}) do
    id
    |> SharedContent.get_public_shared_file!()
    |> case do
      %Uro.SharedContent.SharedFile{} = shared_file ->
        conn
        |> put_status(200)
        |> json(%{
          data: %{
            files:
              Uro.Helpers.SharedContentHelper.get_api_shared_content(
                shared_file,
                %{merge_uploader_id: true, merge_is_public: true}
              )
          }
        })

      _ ->
        put_status(
          conn,
          400
        )
    end
  end

  operation(:create,
    operation_id: "createFile",
    summary: "Upload file to server storage",
    responses: [
      ok: {
        "",
        "application/json",
        %Schema{}
      }
    ]
  )

  def create(conn, %{"storage" => storage_params}) do
    case SharedContent.create_shared_file(
           Uro.Helpers.SharedContentHelper.get_correct_shared_content_params(
             conn,
             storage_params,
             "shared_content_data"
           )
         ) do
      {:ok, stored_file} ->
        conn
        |> put_status(200)
        |> json(%{
          data: %{
            id: to_string(stored_file.id),
            file:
              Uro.Helpers.SharedContentHelper.get_api_shared_content(
                stored_file,
                %{merge_uploader_id: true}
              )
          }
        })

      {:error, %Ecto.Changeset{changes: _changes, errors: _errors} = changeset} ->
        {:error, changeset}
    end
  end

  operation(:update,
    operation_id: "updateSharedFile",
    summary: "Update File",
    responses: [
      ok: {
        "",
        "application/json",
        %Schema{}
      }
    ]
  )

  def update(conn, %{"id" => id, "file" => file_params}) do
    shared_file = SharedContent.get_shared_file!(id)

    case SharedContent.update_shared_file(shared_file, file_params) do
      {:ok, shared_file} ->
        conn
        |> put_status(200)
        |> json(%{
          data: %{
            id: to_string(shared_file.id),
            files:
              Uro.Helpers.SharedContentHelper.get_api_shared_content(
                shared_file,
                %{merge_uploader_id: true}
              )
          }
        })

      {:error, %Ecto.Changeset{changes: _changes, errors: _errors} = changeset} ->
        {:error, changeset}
    end
  end

  operation(:delete,
    operation_id: "deleteSharedFile",
    summary: "Delete File",
    responses: [
      ok: {
        "",
        "application/json",
        %Schema{}
      }
    ]
  )

  operation(:manifest,
    operation_id: "getManifest",
    summary: "Get asset manifest",
    parameters: [
      OpenApiSpex.Operation.parameter(:id, :path, :string, "Asset UUID")
    ],
    responses: [
      ok: {
        "A successful response returning store_url, chunks, and baked_url",
        "application/json",
        %Schema{
          type: :object,
          properties: %{
            data: %Schema{
              type: :object,
              properties: %{
                store_url: %Schema{type: :string},
                chunks: %Schema{type: :array, items: %Schema{type: :object}},
                baked_url: %Schema{type: :string, nullable: true}
              }
            }
          }
        }
      }
    ]
  )

  def manifest(conn, %{"id" => id}) do
    case SharedContent.get_shared_file!(id) do
      %Uro.SharedContent.SharedFile{} = f ->
        json(conn, %{
          data: %{
            store_url: f.store_url,
            chunks: f.chunks || [],
            baked_url: f.baked_url
          }
        })

      _ ->
        conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  operation(:bake,
    operation_id: "setBakedUrl",
    summary: "Set baked_url (baker callback)",
    parameters: [
      OpenApiSpex.Operation.parameter(:id, :path, :string, "Asset UUID")
    ],
    request_body: {
      "",
      "application/json",
      %Schema{
        type: :object,
        required: [:baked_url],
        properties: %{
          baked_url: %Schema{type: :string}
        }
      }
    },
    responses: [
      ok: {
        "",
        "application/json",
        %Schema{
          type: :object,
          properties: %{
            data: %Schema{
              type: :object,
              properties: %{id: %Schema{type: :string}}
            }
          }
        }
      }
    ]
  )

  # Baker callback: accept either a pre-formed baked_url OR raw caibx_data
  # (base64). When caibx_data is supplied, zone-backend stores the index in
  # S3 at zone-chunks/<id>.caibx and constructs the baked_url automatically.
  def bake(conn, %{"id" => id} = params) do
    case SharedContent.get_shared_file!(id) do
      %Uro.SharedContent.SharedFile{} = f ->
        with {:ok, baked_url} <- resolve_baked_url(id, params),
             {:ok, updated} <- SharedContent.set_baked_url(f, baked_url) do
          json(conn, %{data: %{id: to_string(updated.id)}})
        else
          {:error, reason} -> {:error, reason}
        end

      _ ->
        conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  # Store raw .caibx bytes in S3 and return the URL, or pass through baked_url.
  defp resolve_baked_url(id, %{"caibx_data" => b64}) do
    case Base.decode64(b64) do
      {:ok, caibx_bytes} ->
        bucket = Application.get_env(:aria_storage, :waffle_bucket, "zone-chunks")
        key = "#{id}.caibx"
        endpoint = System.get_env("AWS_S3_ENDPOINT", "http://versitygw:7070")

        case ExAws.S3.put_object(bucket, key, caibx_bytes,
               content_type: "application/octet-stream"
             )
             |> ExAws.request() do
          {:ok, _} -> {:ok, "#{endpoint}/#{bucket}/#{key}"}
          {:error, reason} -> {:error, {:s3_put_failed, reason}}
        end

      :error ->
        {:error, :invalid_base64}
    end
  end

  defp resolve_baked_url(_id, %{"baked_url" => baked_url}), do: {:ok, baked_url}
  defp resolve_baked_url(_id, _), do: {:error, :missing_baked_url_or_caibx_data}

  def delete(conn, %{"id" => id}) do
    case SharedContent.get_shared_file!(id) do
      %Uro.SharedContent.SharedFile{} = shared_file ->
        case SharedContent.delete_shared_file(shared_file) do
          {:ok, _shared_file} ->
            conn
            |> put_status(200)
            |> json(%{data: %{}})

          {:error, %Ecto.Changeset{changes: _changes, errors: _errors} = changeset} ->
            {:error, changeset}
        end

      _ ->
        put_status(
          conn,
          200
        )
    end
  end
end

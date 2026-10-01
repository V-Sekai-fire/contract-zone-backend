# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Router do
  use Uro, :router
  use Plug.ErrorHandler
  use Uro.Helpers.API

  # The status is the exception's own, so an unknown route is a 404 and not a 500, and an
  # exit (a crashed task) still gets a JSON body instead of dropping the connection.
  defp handle_errors(conn, %{reason: reason}) do
    json_error(conn,
      code: reason |> Plug.Exception.status() |> Plug.Conn.Status.reason_atom(),
      message:
        if(is_exception(reason), do: Exception.message(reason), else: "Internal Server Error")
    )
  end

  defp handle_errors(conn, _) do
    json_error(conn, code: :internal_server_error)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(:fetch_session)

    plug(RemoteIp)
    plug(Uro.Plug.Authentication, otp_app: :uro)

    plug(OpenApiSpex.Plug.PutApiSpec, module: Uro.OpenAPI.Specification)
  end

  pipeline :authenticated do
    plug(Pow.Plug.RequireAuthenticated, error_handler: Uro.FallbackController)
  end

  pipeline :authenticated_admin do
    plug(Pow.Plug.RequireAuthenticated, error_handler: Uro.FallbackController)
    plug(Uro.Plug.RequireAdmin)
  end

  pipeline :authenticated_shared_file do
    plug(Uro.Plug.RequireSharedFileUploadPermission)
  end

  pipeline :authenticated_user do
    plug(Uro.Plug.ChooseAuth)
  end

  pipeline :dashboard_avatars do
    plug(Uro.Plug.RequireAvatarUploadPermission)
  end

  pipeline :dashboard_maps do
    plug(Uro.Plug.RequireMapUploadPermission)
  end

  pipeline :dashboard_props do
    plug(Uro.Plug.RequirePropUploadPermission)
  end

  if Mix.env() == :dev do
    pipeline :browser do
      plug(:accepts, ["html"])
      plug(:fetch_session)
      plug(:fetch_flash)
      plug(:protect_from_forgery)
      plug(:put_secure_browser_headers)
    end

    scope "/" do
      pipe_through([:browser])

      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end

  # Health — root level, no pipeline (monitoring tools hit this directly).
  get("/", Uro.HealthController, :index)
  get("/health", Uro.HealthController, :index)

  # All API routes under /api/v1.
  scope "/api/v1" do
    pipe_through([:api])

    get("/openapi", OpenApiSpex.Plug.RenderSpec, [])
    get("/docs", Uro.OpenAPI.Viewer, [])

    scope "/registration" do
      post "/", Uro.UserController, :create_client
    end

    scope "/profile" do
      pipe_through([:authenticated_user])
      get("/", Uro.UserController, :show_current)
      post("/totp", Uro.SecondFactorController, :begin_totp)
      post("/totp/confirm", Uro.SecondFactorController, :confirm_totp)
      delete("/totp", Uro.SecondFactorController, :disable_totp)
      get("/passkeys", Uro.PasskeyController, :index)
      post("/passkeys/challenge", Uro.PasskeyController, :registration_challenge)
      post("/passkeys", Uro.PasskeyController, :register)
      delete("/passkeys/:id", Uro.PasskeyController, :delete)
    end

    scope "/session" do
      post("/", Uro.AuthenticationController, :login_client)

      scope "/renew" do
        post("/", Uro.AuthenticationController, :renew)
      end

      pipe_through([:authenticated_user])

      get("/", Uro.AuthenticationController, :get_current_session)
      delete("/", Uro.AuthenticationController, :logout)
    end

    scope "/device" do
      post("/code", Uro.DeviceGrantController, :code)
      post("/token", Uro.DeviceGrantController, :token)

      pipe_through([:authenticated_user])

      get("/", Uro.DeviceGrantController, :show)
      post("/approve", Uro.DeviceGrantController, :approve)
      post("/deny", Uro.DeviceGrantController, :deny)
    end

    scope "/login" do
      post("/", Uro.AuthenticationController, :login)
      post("/passkey/challenge", Uro.PasskeyController, :login_challenge)
      post("/passkey", Uro.PasskeyController, :login)

      scope "/:provider" do
        get("/", Uro.AuthenticationController, :login_with_provider)
        get("/callback", Uro.AuthenticationController, :provider_callback)
      end
    end

    resources("/avatars", Uro.AvatarController, only: [:index, :show])
    resources("/maps", Uro.MapController, only: [:index, :show])

    resources("/shards", Uro.ZoneController, only: [:index, :create, :update, :delete])

    scope "/identity_proofs" do
      pipe_through([:authenticated_user])
      post("/", Uro.IdentityProofController, :create)
      get("/:id", Uro.IdentityProofController, :show)
    end

    post "/loop/commit", Uro.LoopController, :commit

    scope "/admin" do
      pipe_through([:authenticated_admin])

      get("/", Uro.AdminController, :status)
      post("/users/:id/confirm", Uro.AdminController, :confirm_user)
    end

    scope "/storage" do
      scope "/tag" do
        get "/:tag", Uro.StorageController, :index_by_tag
      end

      get "/:id", Uro.StorageController, :show
      post "/:id/manifest", Uro.StorageController, :manifest

      pipe_through([:authenticated_shared_file])

      get "/", Uro.StorageController, :index
      post "/", Uro.StorageController, :create
      put "/:id", Uro.StorageController, :update
      delete "/:id", Uro.StorageController, :delete
      post "/:id/bake", Uro.StorageController, :bake
    end

    scope "/users" do
      post "/", Uro.UserController, :create

      scope "/" do
        pipe_through([:authenticated])
        get "/", Uro.UserController, :index
      end

      scope "/:user_id" do
        get "/", Uro.UserController, :show
        post "/email", Uro.UserController, :confirm_email

        scope "/" do
          pipe_through([:authenticated])

          patch "/", Uro.UserController, :update

          put "/email", Uro.UserController, :update_email
          patch "/email", Uro.UserController, :resend_confirmation_email

          resources("/friend", Uro.FriendController,
            singleton: true,
            only: [:show, :create, :delete]
          )
        end
      end
    end

    scope "/dashboard" do
      pipe_through([:authenticated_user])

      get("/", Uro.AuthenticationController, :get_current_session)
      delete("/", Uro.AuthenticationController, :logout)

      scope "/avatars" do
        pipe_through([:dashboard_avatars])

        get "/", Uro.AvatarController, :index_uploads
        get "/:id", Uro.AvatarController, :show_upload
        post "/", Uro.AvatarController, :create
        put "/:id", Uro.AvatarController, :update
        delete "/:id", Uro.AvatarController, :delete
      end

      scope "/maps" do
        pipe_through([:dashboard_maps])

        get "/", Uro.MapController, :index_uploads
        get "/:id", Uro.MapController, :show_upload
        post "/", Uro.MapController, :create
        put "/:id", Uro.MapController, :update
        delete "/:id", Uro.MapController, :delete
      end

      scope "/props" do
        pipe_through([:dashboard_props])

        get "/", Uro.PropController, :index_uploads
        get "/:id", Uro.PropController, :show_upload
        post "/", Uro.PropController, :create
        put "/:id", Uro.PropController, :update
        delete "/:id", Uro.PropController, :delete
      end
    end
  end

  # Content-addressed chunk server — outside /api/v1, served directly by Caddy.
  scope "/chunks" do
    forward "/", AriaStorage.ChunkServerPlug, writeable: true
  end
end

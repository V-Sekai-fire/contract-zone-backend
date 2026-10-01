# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.ClientRoutesTest do
  @moduledoc """
  What godot_uro's calls get back where the answer was wrong: a closed registration said
  500 and not 403, an unknown route said 500 and not 404, and the shard heartbeat crashed on
  a preload of an association the user has not. Measured through the endpoint, the way the
  client reaches it; `scripts/godot_uro_calls.sh` is the same calls through the client.
  """
  use Uro.RepoCase, async: false

  import Phoenix.ConnTest

  @endpoint Uro.Endpoint

  defp form(conn, path, params), do: post(conn, path, params)

  test "a closed registration is refused with 403, not 500" do
    conn =
      build_conn()
      |> form("/api/v1/registration", %{
        "user" => %{
          "username" => "probe",
          "email" => "probe@example.test",
          "password" => "probe-password-1",
          "password_confirmation" => "probe-password-1",
          "email_notifications" => "false"
        },
        "apiKey" => "not-the-key"
      })

    assert conn.status == 403
    assert %{"message" => "Registration is closed"} = Jason.decode!(conn.resp_body)
  end

  test "an open registration replies in the sign-in shape the client parses" do
    open = Application.get_env(:uro, :registration_open)
    key = System.get_env("SIGNUP_API_KEY")

    on_exit(fn ->
      Application.put_env(:uro, :registration_open, open)
      if key, do: System.put_env("SIGNUP_API_KEY", key), else: System.delete_env("SIGNUP_API_KEY")
    end)

    # No mail server is attached in this environment, so the account is created unconfirmed
    # and no email is attempted.
    refute Uro.Mailer.attached?()
    Application.put_env(:uro, :registration_open, true)
    System.put_env("SIGNUP_API_KEY", "probe-key")
    n = System.unique_integer([:positive])

    conn =
      build_conn()
      |> form("/api/v1/registration", %{
        "user" => %{
          "username" => "probe#{n}",
          "email" => "probe#{n}@example.test",
          "password" => "probe-password-1",
          "password_confirmation" => "probe-password-1",
          "email_notifications" => "false"
        },
        "apiKey" => "probe-key"
      })

    assert conn.status == 200

    assert %{
             "data" => %{
               "access_token" => token,
               "renewal_token" => token,
               "user" => %{"username" => username},
               "user_privilege_ruleset" => %{"can_upload_avatars" => false}
             }
           } = Jason.decode!(conn.resp_body)

    assert is_binary(token) and token != ""
    assert username == "probe#{n}"
  end

  defp sign_in(username, password) do
    conn =
      form(build_conn(), "/api/v1/session", %{
        "user" => %{"username_or_email" => username, "password" => password}
      })

    assert conn.status == 200
    %{"data" => %{"access_token" => token}} = Jason.decode!(conn.resp_body)
    token
  end

  defp make_user(name, admin?) do
    {:ok, user} =
      Uro.Accounts.create(%{
        "email" => "#{name}@example.test",
        "username" => name,
        "display_name" => name,
        "password" => "probe-password-1"
      })

    user = Uro.Accounts.get_user!(user.id)

    user.user_privilege_ruleset
    |> Uro.Accounts.UserPrivilegeRuleset.admin_changeset(%{is_admin: admin?})
    |> Repo.update!()

    user
  end

  test "an admin confirms an account in place of the emailed token, and a user cannot" do
    n = System.unique_integer([:positive])
    admin = make_user("admin#{n}", true)
    user = make_user("plain#{n}", false)
    assert is_nil(user.email_confirmed_at)

    refused =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", sign_in(user.username, "probe-password-1"))
      |> post("/api/v1/admin/users/#{user.id}/confirm")

    assert refused.status == 403
    assert is_nil(Uro.Accounts.get_user!(user.id).email_confirmed_at)

    confirmed =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", sign_in(admin.username, "probe-password-1"))
      |> post("/api/v1/admin/users/#{user.id}/confirm")

    assert confirmed.status == 200
    refute is_nil(Uro.Accounts.get_user!(user.id).email_confirmed_at)
  end

  test "an unknown route is 404 json, not 500" do
    # The router's error handler sends the reply on its own copy of the conn, so the
    # response is read back from the test adapter rather than from the returned conn.
    conn = get(build_conn(), "/api/v1/profilx")
    {status, _headers, body} = Plug.Test.sent_resp(conn)
    assert status == 404
    assert %{"code" => "not_found"} = Jason.decode!(body)
  end

  test "control: a route that is there is not 404" do
    assert get(build_conn(), "/api/v1/shards").status == 200
  end

  test "the shard heartbeat updates an anonymous shard from its own address" do
    created =
      build_conn()
      |> form("/api/v1/shards", %{
        "shard" => %{
          "name" => "probe",
          "map" => "probe_map",
          "port" => "7777",
          "max_users" => "8"
        }
      })

    assert created.status == 200
    %{"data" => %{"id" => id}} = Jason.decode!(created.resp_body)

    beat = put(build_conn(), "/api/v1/shards/#{id}", %{"shard" => %{"current_users" => "1"}})
    assert beat.status == 200

    gone = delete(build_conn(), "/api/v1/shards/#{id}", %{"shard" => %{}})
    assert gone.status == 200
  end
end

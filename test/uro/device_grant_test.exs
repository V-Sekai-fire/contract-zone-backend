defmodule Uro.DeviceGrantTest do
  use Uro.RepoCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Uro.Accounts
  alias Uro.DeviceGrant

  @endpoint Uro.Endpoint
  @t0 ~U[2030-01-01 00:00:00Z]

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create(%{
        "email" => "device#{n}@example.test",
        "username" => "device#{n}",
        "display_name" => "Device User",
        "password" => "correct horse battery"
      })

    %{user: user}
  end

  defp at(seconds), do: DateTime.add(@t0, seconds)

  defp poll(code, seconds),
    do:
      DeviceGrant.poll(
        %{"grant_type" => DeviceGrant.grant_type(), "device_code" => code},
        at(seconds)
      )

  test "a device that waits is pending, then signs in once the user approves", %{user: user} do
    {:ok, auth} = DeviceGrant.start("headset", @t0)
    assert auth.verification_uri_complete =~ "https://uro.test/device?user_code="
    assert {:error, "authorization_pending"} == poll(auth.device_code, 0)
    assert :ok == DeviceGrant.approve(user, auth.user_code, at(3))
    assert {:ok, signed_in} = poll(auth.device_code, 6)
    assert signed_in.id == user.id
  end

  test "the user code is accepted in lower case and without its dash", %{user: user} do
    {:ok, auth} = DeviceGrant.start("headset", @t0)
    loose = auth.user_code |> String.downcase() |> String.replace("-", "")
    assert {:ok, %{client_id: "headset"}} = DeviceGrant.lookup(loose, at(1))
    assert :ok == DeviceGrant.approve(user, loose, at(1))
  end

  test "control: a device polling faster than its interval is told to slow down" do
    {:ok, auth} = DeviceGrant.start("headset", @t0)
    assert {:error, "authorization_pending"} == poll(auth.device_code, 0)
    assert {:error, "slow_down"} == poll(auth.device_code, 2)
    # Each slow_down adds 5 s: the interval is now 10 s, so 7 s after the last poll is too soon,
    # and that second slow_down makes it 15 s.
    assert {:error, "slow_down"} == poll(auth.device_code, 9)
    assert {:error, "slow_down"} == poll(auth.device_code, 20)
    assert {:error, "authorization_pending"} == poll(auth.device_code, 40)
  end

  test "control: a denied device is refused, and its code is spent", %{user: user} do
    {:ok, auth} = DeviceGrant.start("headset", @t0)
    assert :ok == DeviceGrant.deny(user, auth.user_code, at(1))
    assert {:error, "access_denied"} == poll(auth.device_code, 6)
    assert {:error, "invalid_grant"} == poll(auth.device_code, 12)
  end

  test "control: an expired code is refused and can no longer be approved", %{user: user} do
    {:ok, auth} = DeviceGrant.start("headset", @t0)
    assert {:error, "expired_token"} == poll(auth.device_code, 600)
    assert {:error, :not_found} == DeviceGrant.approve(user, auth.user_code, at(601))
  end

  test "control: a device code redeems once", %{user: user} do
    {:ok, auth} = DeviceGrant.start("headset", @t0)
    :ok = DeviceGrant.approve(user, auth.user_code, at(1))
    assert {:ok, _} = poll(auth.device_code, 6)
    assert {:error, "invalid_grant"} == poll(auth.device_code, 12)
  end

  test "control: an unknown device code, a wrong client and a wrong grant type are refused" do
    {:ok, auth} = DeviceGrant.start("headset", @t0)
    assert {:error, "invalid_grant"} == poll("not-a-device-code", 0)

    assert {:error, "invalid_client"} ==
             DeviceGrant.poll(
               %{
                 "grant_type" => DeviceGrant.grant_type(),
                 "device_code" => auth.device_code,
                 "client_id" => "other"
               },
               at(0)
             )

    assert {:error, "unsupported_grant_type"} ==
             DeviceGrant.poll(
               %{"grant_type" => "password", "device_code" => auth.device_code},
               at(0)
             )
  end

  test "control: a code cannot be approved twice, or approved after a denial", %{user: user} do
    {:ok, auth} = DeviceGrant.start("headset", @t0)
    :ok = DeviceGrant.approve(user, auth.user_code, at(1))
    assert {:error, :not_found} == DeviceGrant.approve(user, auth.user_code, at(2))
    assert {:error, :not_found} == DeviceGrant.deny(user, auth.user_code, at(2))
  end

  test "control: starting without a client id is refused" do
    assert {:error, :invalid_client} == DeviceGrant.start("", @t0)
    assert {:error, :invalid_client} == DeviceGrant.start(nil, @t0)
  end

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  test "the HTTP routes answer RFC 8628's shapes: codes, a 400 error code, then a session",
       %{user: user} do
    codes = json_response(post_json("/api/v1/device/code", %{"client_id" => "headset"}), 200)
    assert %{"device_code" => device_code, "user_code" => user_code, "interval" => 5} = codes

    body = %{"grant_type" => DeviceGrant.grant_type(), "device_code" => device_code}

    assert %{"error" => "authorization_pending"} ==
             json_response(post_json("/api/v1/device/token", body), 400)

    :ok = DeviceGrant.approve(user, user_code)
    # The route polls on the wall clock; wait out the interval rather than tripping slow_down.
    Process.sleep(5_100)

    assert %{"data" => %{"access_token" => token}} =
             json_response(post_json("/api/v1/device/token", body), 200)

    assert is_binary(token)
  end
end

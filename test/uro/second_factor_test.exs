defmodule Uro.SecondFactorTest do
  use Uro.RepoCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Uro.Accounts
  alias Uro.Accounts.TOTP
  alias Uro.SecondFactor

  @endpoint Uro.Endpoint
  @password "correct horse battery"
  @now 1_900_000_000

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create(%{
        "email" => "twostep#{n}@example.test",
        "username" => "twostep#{n}",
        "display_name" => "Two Step",
        "password" => @password
      })

    %{user: user}
  end

  defp enrol(user, now \\ @now) do
    {:ok, %{secret: b32}} = SecondFactor.begin_totp(user)
    secret = Base.decode32!(b32, padding: false)
    {:ok, codes} = SecondFactor.confirm_totp(user, TOTP.code(secret, TOTP.step(now)), now)
    {secret, codes}
  end

  test "without an authenticator a password alone signs in", %{user: user} do
    assert :ok == SecondFactor.check(user, %{})
    refute SecondFactor.enabled?(user)
  end

  test "enrolment confirmed with a current code turns it on and returns ten backup codes",
       %{user: user} do
    {_secret, codes} = enrol(user)
    assert SecondFactor.enabled?(user)
    assert length(codes) == 10
    assert length(Enum.uniq(codes)) == 10
  end

  test "control: a wrong confirmation code leaves the authenticator off", %{user: user} do
    {:ok, _} = SecondFactor.begin_totp(user)
    assert {:error, :invalid_second_factor} == SecondFactor.confirm_totp(user, "000000", @now)
    refute SecondFactor.enabled?(user)
  end

  test "once enabled, a password alone is refused", %{user: user} do
    enrol(user)
    assert {:error, :second_factor_required} == SecondFactor.check(user, %{})
  end

  test "a code passes once, and the same code again is a replay", %{user: user} do
    {secret, _} = enrol(user)
    code = TOTP.code(secret, TOTP.step(@now + 30))
    assert :ok == SecondFactor.check(user, %{"totp_code" => code}, @now + 30)

    assert {:error, :invalid_second_factor} ==
             SecondFactor.check(user, %{"totp_code" => code}, @now + 30)
  end

  test "control: the code that confirmed enrolment cannot sign in", %{user: user} do
    {secret, _} = enrol(user)
    code = TOTP.code(secret, TOTP.step(@now))

    assert {:error, :invalid_second_factor} ==
             SecondFactor.check(user, %{"totp_code" => code}, @now)
  end

  test "a backup code passes once, in any case and with or without its dash", %{user: user} do
    {_, [code | _]} = enrol(user)
    loose = code |> String.downcase() |> String.replace("-", "")
    assert :ok == SecondFactor.check(user, %{"backup_code" => loose})
    assert {:error, :invalid_second_factor} == SecondFactor.check(user, %{"backup_code" => code})
  end

  test "control: another user's backup code is refused", %{user: user} do
    {_, [code | _]} = enrol(user)
    n = System.unique_integer([:positive])

    {:ok, other} =
      Accounts.create(%{
        "email" => "other#{n}@example.test",
        "username" => "other#{n}",
        "display_name" => "Other",
        "password" => @password
      })

    enrol(other)
    assert {:error, :invalid_second_factor} == SecondFactor.check(other, %{"backup_code" => code})
  end

  test "disabling needs a fresh code, then a password alone signs in again", %{user: user} do
    {secret, _} = enrol(user)
    assert {:error, :second_factor_required} == SecondFactor.disable_totp(user, %{}, @now + 30)
    code = TOTP.code(secret, TOTP.step(@now + 30))
    assert :ok == SecondFactor.disable_totp(user, %{"totp_code" => code}, @now + 30)
    refute SecondFactor.enabled?(user)
    assert :ok == SecondFactor.check(user, %{})
  end

  defp login(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/login", Jason.encode!(body))
  end

  test "the login route asks for the second step and accepts a current code", %{user: user} do
    {secret, _} = enrol(user, System.os_time(:second) - 60)
    creds = %{"email" => user.email, "password" => @password}

    conn = login(creds)
    assert conn.status == 401
    assert conn.resp_body =~ "Second factor required"

    code = TOTP.code(secret, TOTP.step(System.os_time(:second)))
    assert login(Map.put(creds, "totp_code", code)).status == 200
  end

  test "control: the login route still refuses a wrong password with a valid code", %{user: user} do
    {secret, _} = enrol(user, System.os_time(:second) - 60)
    code = TOTP.code(secret, TOTP.step(System.os_time(:second)))
    conn = login(%{"email" => user.email, "password" => "wrong", "totp_code" => code})
    assert conn.status == 401
    assert conn.resp_body =~ "Invalid credentials"
  end

  test "control: without an authenticator the login route takes a password alone", %{user: user} do
    assert login(%{"email" => user.email, "password" => @password}).status == 200
  end
end

defmodule Uro.RegistrationTest do
  use Uro.RepoCase, async: false

  alias Uro.Accounts.User
  alias Uro.Registration
  alias Uro.UserIdentities

  @identity %{
    "provider" => "github",
    "uid" => "4242",
    "token" => %{"access_token" => "t"},
    "userinfo" => %{
      "preferred_username" => "newcomer",
      "name" => "New Comer",
      "email" => "new@example.test"
    }
  }
  @user %{"username" => "newcomer"}
  @user_id %{"email" => "new@example.test"}

  setup do
    open = Application.get_env(:uro, :registration_open)
    key = System.get_env("SIGNUP_API_KEY")

    on_exit(fn ->
      Application.put_env(:uro, :registration_open, open)
      if key, do: System.put_env("SIGNUP_API_KEY", key), else: System.delete_env("SIGNUP_API_KEY")
    end)
  end

  test "a first sign-in through a provider creates no account while registration is closed" do
    Application.put_env(:uro, :registration_open, false)
    assert {:error, :registration_closed} = UserIdentities.create_user(@identity, @user, @user_id)
    assert Repo.aggregate(User, :count) == 0
  end

  test "control: the same sign-in creates the account when registration is open" do
    Application.put_env(:uro, :registration_open, true)

    assert {:ok, %User{username: "newcomer"}} =
             UserIdentities.create_user(@identity, @user, @user_id)

    assert Repo.aggregate(User, :count) == 1
  end

  test "an unset sign-up key matches nothing, a null key included" do
    System.delete_env("SIGNUP_API_KEY")
    refute Registration.signup_key_valid?(nil)
    refute Registration.signup_key_valid?("")
  end

  test "control: a configured sign-up key matches itself and nothing else" do
    System.put_env("SIGNUP_API_KEY", "k3y")
    assert Registration.signup_key_valid?("k3y")
    refute Registration.signup_key_valid?("other")
    refute Registration.signup_key_valid?(nil)
  end
end

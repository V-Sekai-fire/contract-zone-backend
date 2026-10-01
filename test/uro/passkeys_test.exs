defmodule Uro.PasskeysTest do
  use Uro.RepoCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Uro.Accounts
  alias Uro.Passkeys

  @endpoint Uro.Endpoint

  # A software authenticator: one P-256 key, "none" attestation, flags and count as asked.
  defmodule Authenticator do
    def new do
      {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
      <<4, x::binary-size(32), y::binary-size(32)>> = pub
      %{priv: priv, x: x, y: y, cred_id: :crypto.strong_rand_bytes(16)}
    end

    def attestation(a, challenge, opts \\ []) do
      cose = %{1 => 2, 3 => -7, -1 => 1, -2 => bytes(a.x), -3 => bytes(a.y)}
      attested = <<0::128, byte_size(a.cred_id)::16>> <> a.cred_id <> CBOR.encode(cose)
      auth_data = auth_data(opts, 0x45, 0) <> attested
      att = CBOR.encode(%{"fmt" => "none", "attStmt" => %{}, "authData" => bytes(auth_data)})

      %{
        "attestation_object" => b64(att),
        "client_data_json" => b64(client_data("webauthn.create", challenge, opts))
      }
    end

    def assertion(a, challenge, opts \\ []) do
      auth_data = auth_data(opts, Keyword.get(opts, :flags, 0x05), Keyword.get(opts, :count, 1))
      client_data = client_data("webauthn.get", challenge, opts)
      priv = Keyword.get(opts, :priv, a.priv)

      sig =
        :crypto.sign(:ecdsa, :sha256, auth_data <> :crypto.hash(:sha256, client_data), [
          priv,
          :secp256r1
        ])

      %{
        "credential_id" => b64(a.cred_id),
        "authenticator_data" => b64(auth_data),
        "client_data_json" => b64(client_data),
        "signature" => b64(sig)
      }
    end

    defp auth_data(opts, flags, count),
      do: :crypto.hash(:sha256, Keyword.get(opts, :rp_id, "uro.test")) <> <<flags, count::32>>

    defp client_data(type, challenge, opts) do
      Jason.encode!(%{
        "type" => type,
        "challenge" => challenge,
        "origin" => Keyword.get(opts, :origin, "https://uro.test"),
        "crossOrigin" => false
      })
    end

    defp bytes(b), do: %CBOR.Tag{tag: :bytes, value: b}
    def b64(b), do: Base.url_encode64(b, padding: false)
  end

  setup do
    %{user: user("pk"), key: Authenticator.new()}
  end

  defp user(prefix) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create(%{
        "email" => "#{prefix}#{n}@example.test",
        "username" => "#{prefix}#{n}",
        "display_name" => "Passkey User",
        "password" => "correct horse battery"
      })

    user
  end

  defp register(user, key, opts \\ []) do
    {:ok, %{challenge_id: cid, public_key: %{challenge: challenge}}} =
      Passkeys.registration_options(user)

    Passkeys.register(
      user,
      Map.put(Authenticator.attestation(key, challenge, opts), "challenge_id", cid)
    )
  end

  defp sign_in_params(key, opts \\ []) do
    {:ok, %{challenge_id: cid, public_key: %{challenge: challenge}}} = Passkeys.login_options()
    Map.put(Authenticator.assertion(key, challenge, opts), "challenge_id", cid)
  end

  test "a registered passkey signs its user in, naming no account", %{user: user, key: key} do
    assert {:ok, _passkey} = register(user, key)
    assert {:ok, signed_in} = Passkeys.authenticate(sign_in_params(key))
    assert signed_in.id == user.id
  end

  test "control: a registration from another origin is refused", %{user: user, key: key} do
    assert {:error, :invalid_passkey} == register(user, key, origin: "https://evil.test")
    assert [] == Passkeys.list(user)
  end

  test "control: another user's registration challenge is refused", %{user: user, key: key} do
    {:ok, %{challenge_id: cid, public_key: %{challenge: challenge}}} =
      Passkeys.registration_options(user("other"))

    params = Map.put(Authenticator.attestation(key, challenge), "challenge_id", cid)
    assert {:error, :invalid_passkey} == Passkeys.register(user, params)
  end

  test "control: an assertion signed by another key is refused", %{user: user, key: key} do
    {:ok, _} = register(user, key)
    other = Authenticator.new()

    assert {:error, :invalid_passkey} ==
             Passkeys.authenticate(sign_in_params(key, priv: other.priv))
  end

  test "control: a spent sign-in challenge cannot carry the same assertion again",
       %{user: user, key: key} do
    {:ok, _} = register(user, key)
    params = sign_in_params(key)
    assert {:ok, _} = Passkeys.authenticate(params)
    assert {:error, :invalid_passkey} == Passkeys.authenticate(params)
  end

  test "control: an assertion without user verification is refused", %{user: user, key: key} do
    {:ok, _} = register(user, key)
    assert {:error, :invalid_passkey} == Passkeys.authenticate(sign_in_params(key, flags: 0x01))
  end

  test "control: a signature count that falls is refused", %{user: user, key: key} do
    {:ok, _} = register(user, key)
    assert {:ok, _} = Passkeys.authenticate(sign_in_params(key, count: 5))
    assert {:error, :invalid_passkey} == Passkeys.authenticate(sign_in_params(key, count: 3))
  end

  test "an authenticator that keeps no counter signs in every time", %{user: user, key: key} do
    {:ok, _} = register(user, key)
    assert {:ok, _} = Passkeys.authenticate(sign_in_params(key, count: 0))
    assert {:ok, _} = Passkeys.authenticate(sign_in_params(key, count: 0))
  end

  test "control: a user handle naming someone else is refused", %{user: user, key: key} do
    {:ok, _} = register(user, key)
    other = user("handle")
    handle = Authenticator.b64(Ecto.UUID.dump!(other.id))
    params = key |> sign_in_params() |> Map.put("user_handle", handle)
    assert {:error, :invalid_passkey} == Passkeys.authenticate(params)
  end

  test "a removed passkey no longer signs in", %{user: user, key: key} do
    {:ok, passkey} = register(user, key)
    assert :ok == Passkeys.delete(user, passkey.id)
    assert {:error, :invalid_passkey} == Passkeys.authenticate(sign_in_params(key))
  end

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  test "the passkey sign-in route returns a session for a good assertion and 401 for a bad one",
       %{user: user, key: key} do
    {:ok, _} = register(user, key)

    challenge = json_response(post_json("/api/v1/login/passkey/challenge", %{}), 200)["data"]
    good = Authenticator.assertion(key, challenge["public_key"]["challenge"])

    conn =
      post_json("/api/v1/login/passkey", Map.put(good, "challenge_id", challenge["challenge_id"]))

    assert %{"data" => %{"access_token" => token}} = json_response(conn, 200)
    assert is_binary(token)

    challenge = json_response(post_json("/api/v1/login/passkey/challenge", %{}), 200)["data"]

    bad =
      Authenticator.assertion(key, challenge["public_key"]["challenge"],
        origin: "https://evil.test"
      )

    conn =
      post_json("/api/v1/login/passkey", Map.put(bad, "challenge_id", challenge["challenge_id"]))

    assert conn.status == 401
    assert conn.resp_body =~ "Invalid passkey"
  end
end

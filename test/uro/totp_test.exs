defmodule Uro.TOTPTest do
  use ExUnit.Case, async: true

  alias Uro.Accounts.TOTP

  @secret "12345678901234567890"

  # RFC 6238 appendix B, HMAC-SHA1, the 8-digit codes cut to their last 6.
  for {t, code} <- [
        {59, "287082"},
        {1_111_111_109, "081804"},
        {1_111_111_111, "050471"},
        {1_234_567_890, "005924"},
        {2_000_000_000, "279037"},
        {20_000_000_000, "353130"}
      ] do
    test "RFC 6238 vector at t=#{t}" do
      assert TOTP.code(@secret, TOTP.step(unquote(t))) == unquote(code)
    end
  end

  test "a code is accepted one step either side of now" do
    now = 1_111_111_111
    s = TOTP.step(now)

    for d <- [-1, 0, 1] do
      assert {:ok, s + d} == TOTP.verify(@secret, TOTP.code(@secret, s + d), now, 0)
    end
  end

  test "control: a code two steps away is refused" do
    now = 1_111_111_111
    s = TOTP.step(now)
    assert :error == TOTP.verify(@secret, TOTP.code(@secret, s + 2), now, 0)
    assert :error == TOTP.verify(@secret, TOTP.code(@secret, s - 2), now, 0)
  end

  test "control: a step at or before the last accepted one is a replay" do
    now = 1_111_111_111
    s = TOTP.step(now)
    assert :error == TOTP.verify(@secret, TOTP.code(@secret, s), now, s)
    assert {:ok, s} == TOTP.verify(@secret, TOTP.code(@secret, s), now, s - 1)
  end

  test "control: a wrong code, or no code, is refused" do
    assert :error == TOTP.verify(@secret, "000000", 59, 0)
    assert :error == TOTP.verify(@secret, nil, 59, 0)
  end

  test "the provisioning URI carries the base32 secret and the issuer" do
    uri = TOTP.uri(@secret, "me@example.test")
    assert uri =~ "otpauth://totp/Uro:me@example.test?"
    assert uri =~ "secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    assert uri =~ "issuer=Uro"
  end
end

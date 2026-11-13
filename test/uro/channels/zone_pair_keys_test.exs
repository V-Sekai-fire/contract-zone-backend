# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.ZonePairKeysTest do
  @moduledoc """
  The members of `zone:<id>` are pushed `"pair_keys"` when the member set changes.

  Pushes to every socket a test process opens arrive in that one process, with nothing to
  tell them apart. So each member here has its own transport process, as each client has
  its own connection: the socket is connected by the test (`Phoenix.ChannelTest` allows
  no other process to), its transport is set to a process that forwards each push to the
  test as `{:pushed, name, event, payload}`, and then it joins.

  The zones are public, because today `Uro.VSekai.can_enter_zone?/2` admits only the owner
  to a private one. Zone ids repeat between tests, so `zone/0` empties the zone's table and
  its keys when the test exits.
  """
  use Uro.ChannelCase

  import ExUnit.CaptureLog

  alias Uro.UserSocket
  alias Uro.VSekai.Zone
  alias Uro.Zones.PairKeys
  alias Uro.Zones.Slots

  defp zone do
    zone =
      Repo.insert!(%Zone{
        address: "127.0.0.1",
        port: 7443,
        map: "no-such-map",
        name: "keys",
        public: true
      })

    on_exit(fn ->
      for user_id <- Slots.table(zone.id), user_id != nil, do: Slots.leave(zone.id, user_id)
      PairKeys.refresh(zone.id)
    end)

    zone
  end

  defp member(name, zone) do
    test = self()
    forwarder = spawn_link(fn -> forward(test, name) end)
    {:ok, socket} = connect(UserSocket, %{"token" => sign_in(make_user(name))})

    {:ok, reply, socket} =
      subscribe_and_join(%{socket | transport_pid: forwarder}, "zone:#{zone.id}")

    Process.unlink(socket.channel_pid)
    {socket, reply.slot}
  end

  defp forward(test, name) do
    receive do
      %Phoenix.Socket.Message{event: event, payload: payload} ->
        send(test, {:pushed, name, event, payload})

      _reply ->
        :ok
    end

    forward(test, name)
  end

  defp leave_and_wait(socket) do
    monitor = Process.monitor(socket.channel_pid)
    leave(socket)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 2_000
  end

  defp keys_of(name, count) do
    assert_receive {:pushed, ^name, "pair_keys", %{keys: keys}} when map_size(keys) == count,
                   2_000

    keys
  end

  defp drain(acc \\ []) do
    receive do
      {:pushed, name, event, payload} -> drain([{name, event, payload} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  test "a member who is alone is pushed pair_keys with no key" do
    zone = zone()
    {_socket, 0} = member("a", zone)

    assert_receive {:pushed, "a", "pair_keys", payload}, 2_000
    assert payload == %{keys: %{}}
  end

  test "three members each get the two keys of their pairs, and nobody a key of the other two" do
    zone = zone()
    for {name, slot} <- [{"a", 0}, {"b", 1}, {"c", 2}], do: {_socket, ^slot} = member(name, zone)

    a = keys_of("a", 2)
    b = keys_of("b", 2)
    c = keys_of("c", 2)

    assert [Map.keys(a), Map.keys(b), Map.keys(c)] == [~w(1 2), ~w(0 2), ~w(0 1)]
    assert a["1"] == b["0"]
    assert a["2"] == c["0"]
    assert b["2"] == c["1"]

    pairs = %{"a" => [a["1"], a["2"]], "b" => [b["0"], b["2"]], "c" => [c["0"], c["1"]]}
    assert length(Enum.uniq(List.flatten(Map.values(pairs)))) == 3
    for key <- List.flatten(Map.values(pairs)), do: assert(byte_size(Base.decode64!(key)) == 32)

    pushed = [{"a", "pair_keys", %{keys: a}}, {"b", "pair_keys", %{keys: b}}] ++ drain()
    pushed = [{"c", "pair_keys", %{keys: c}} | pushed]

    for {name, event, payload} <- pushed do
      assert event == "pair_keys", "#{name} was pushed #{event}"
      assert Map.keys(payload) == [:keys]

      assert Map.values(payload.keys) -- pairs[name] == [],
             "#{name} was pushed a key of a pair it is not in"
    end

    refute b["2"] in Map.values(a)
    refute a["2"] in Map.values(b)
    refute a["1"] in Map.values(c)
  end

  test "after one of three leaves, the two who stay get one key, the one they had" do
    zone = zone()
    [{_a, 0}, {_b, 1}, {c, 2}] = for name <- ~w(a b c), do: member(name, zone)

    a = keys_of("a", 2)
    b = keys_of("b", 2)
    keys_of("c", 2)
    drain()

    leave_and_wait(c)

    assert keys_of("a", 1) == %{"1" => a["1"]}
    assert keys_of("b", 1) == %{"0" => b["0"]}
    assert a["1"] == b["0"]
    assert Slots.table(zone.id) |> Enum.count(&(&1 != nil)) == 2

    for {name, event, payload} <- drain() do
      assert name in ~w(a b), "#{name} was pushed #{event} after leaving"
      assert payload == %{keys: %{((name == "a" && "1") || "0") => a["1"]}}
    end
  end

  test "a member who joins after a leave shares new keys, and the old pair's key is gone" do
    zone = zone()
    [{_a, 0}, {b_socket, 1}] = for name <- ~w(a b), do: member(name, zone)
    %{"1" => old} = keys_of("a", 1)
    drain()

    leave_and_wait(b_socket)
    assert keys_of("a", 0) == %{}

    {_d, 1} = member("d", zone)
    %{"1" => new} = keys_of("a", 1)
    assert keys_of("d", 1) == %{"0" => new}
    assert new != old
  end

  test "control: the keys are not in the log" do
    zone = zone()

    {keys, log} =
      with_log(fn ->
        for name <- ~w(a b), do: member(name, zone)
        keys = keys_of("a", 1)
        keys_of("b", 1)
        keys
      end)

    %{"1" => key} = keys
    refute log =~ key
    refute log =~ "pair_keys"
    assert log =~ "JOINED zone:#{zone.id}"
  end
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.ZoneChannelTest do
  @moduledoc """
  Joining `zone:<id>` asks `Uro.VSekai.can_enter_zone?/2` and then takes one of the zone's
  four slots. Today that rule admits anyone to a public zone and only the owner to a
  private one, so the tests with several members use a public zone.
  """
  use Uro.ChannelCase

  alias Uro.UserSocket
  alias Uro.VSekai.Zone
  alias Uro.Zones.Slots

  defp zone(attrs) do
    zone =
      Repo.insert!(
        %Zone{address: "127.0.0.1", port: 7443, map: "no-such-map", name: "slots"}
        |> Map.merge(attrs)
      )

    # Zone ids repeat between tests (the sandbox rolls the rows back), so no seat may
    # outlive the test that took it.
    on_exit(fn ->
      for user_id <- Slots.table(zone.id), user_id != nil, do: Slots.leave(zone.id, user_id)
    end)

    zone
  end

  defp socket_for(user) do
    {:ok, socket} = connect(UserSocket, %{"token" => sign_in(user)})
    socket
  end

  defp empty, do: [nil, nil, nil, nil]

  test "the owner of a private zone joins and gets a slot and the table" do
    owner = make_user("owner")
    zone = zone(%{public: false, user_id: owner.id})

    assert {:ok, reply, _socket} = subscribe_and_join(socket_for(owner), "zone:#{zone.id}")
    assert reply == %{desync_index_url: nil, slot: 0, slots: [owner.id, nil, nil, nil]}
    assert Slots.table(zone.id) == [owner.id, nil, nil, nil]
  end

  test "control: a signed-in user who may not enter a private zone is refused" do
    owner = make_user("owner")
    stranger = make_user("stranger")
    zone = zone(%{public: false, user_id: owner.id})

    assert subscribe_and_join(socket_for(stranger), "zone:#{zone.id}") ==
             {:error, %{reason: "not allowed"}}

    assert Slots.table(zone.id) == empty()
  end

  test "after the owner leaves, the slot is free" do
    owner = make_user("owner")
    zone = zone(%{public: false, user_id: owner.id})
    {:ok, _reply, socket} = subscribe_and_join(socket_for(owner), "zone:#{zone.id}")
    assert Slots.table(zone.id) == [owner.id, nil, nil, nil]

    Process.unlink(socket.channel_pid)
    monitor = Process.monitor(socket.channel_pid)
    ref = leave(socket)
    assert_reply ref, :ok
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}

    assert Slots.table(zone.id) == empty()
  end

  test "when the connection closes, the slot is free" do
    owner = make_user("owner")
    zone = zone(%{public: false, user_id: owner.id})
    {:ok, _reply, socket} = subscribe_and_join(socket_for(owner), "zone:#{zone.id}")

    Process.unlink(socket.channel_pid)
    monitor = Process.monitor(socket.channel_pid)
    :ok = close(socket)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}

    assert Slots.table(zone.id) == empty()
  end

  test "a public zone seats four users in order; control: the fifth is refused" do
    zone = zone(%{public: true})
    users = for n <- 1..5, do: make_user("member#{n}_")
    {seated, [fifth]} = Enum.split(users, 4)

    for {user, slot} <- Enum.with_index(seated) do
      assert {:ok, %{slot: ^slot}, _socket} =
               subscribe_and_join(socket_for(user), "zone:#{zone.id}")
    end

    ids = Enum.map(seated, & &1.id)
    assert Slots.table(zone.id) == ids

    assert subscribe_and_join(socket_for(fifth), "zone:#{zone.id}") ==
             {:error, %{reason: "zone full"}}

    assert Slots.table(zone.id) == ids
  end

  test "a member who joins again keeps their slot" do
    zone = zone(%{public: true})
    [a, b] = [make_user("a"), make_user("b")]
    {:ok, %{slot: 0}, _} = subscribe_and_join(socket_for(a), "zone:#{zone.id}")
    {:ok, %{slot: 1}, _} = subscribe_and_join(socket_for(b), "zone:#{zone.id}")

    assert {:ok, %{slot: 1, slots: slots}, _} =
             subscribe_and_join(socket_for(b), "zone:#{zone.id}")

    assert slots == [a.id, b.id, nil, nil]
  end

  test "a joined client still receives zone_updated" do
    owner = make_user("owner")
    zone = zone(%{public: false, user_id: owner.id})
    {:ok, _reply, _socket} = subscribe_and_join(socket_for(owner), "zone:#{zone.id}")

    Uro.Endpoint.broadcast("zone:#{zone.id}", "zone_updated", %{desync_index_url: "u"})
    assert_push "zone_updated", %{desync_index_url: "u"}
  end

  test "control: a zone that does not exist is refused as before" do
    assert subscribe_and_join(socket_for(make_user("lost")), "zone:999999999") ==
             {:error, %{reason: "zone not found"}}
  end
end

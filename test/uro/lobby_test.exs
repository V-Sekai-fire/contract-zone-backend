# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.LobbyTest do
  @moduledoc """
  The OMI lobby lists Basis and Overte servers and refreshes their health on a timer.
  Basis answers an unconnected UDP info query on its game port; Overte domains heartbeat
  to the Overte directory, which the lobby reads.
  """
  use Uro.RepoCase, async: false

  import Phoenix.ConnTest

  alias Uro.Lobby
  alias Uro.Lobby.BasisQuery
  alias Uro.Lobby.OverteDirectory

  @endpoint Uro.Endpoint

  # A real reply from server1.basisvr.org:4296 to nonce 0xBEEF (captured 2026-10-10).
  @basis_reply Base.decode16!(
                 "08025151BA0100EFBE0100881312006D61696E206261736973207365727665721300616E6F746865722062726967687420646179"
               )

  describe "Basis info query" do
    test "the query is one LiteNetLib unconnected message padded to the server's minimum" do
      packet = BasisQuery.encode_query(0xBEEF)
      assert byte_size(packet) == 1 + 384
      assert <<8, 0xBA515101::little-32, 1::little-16, 0xBEEF::little-16, pad::binary>> = packet
      assert pad == :binary.copy(<<0>>, 384 - 8)
    end

    test "the captured reply decodes to name, online, capacity and motd" do
      assert {:ok,
              %{
                name: "main basis server",
                motd: "another bright day",
                online: 1,
                capacity: 5000
              }} = BasisQuery.decode_reply(@basis_reply, 0xBEEF)
    end

    test "control: a reply to another nonce, a wrong magic or a truncated reply is refused" do
      assert {:error, :nonce_mismatch} = BasisQuery.decode_reply(@basis_reply, 0x0001)

      <<head, _magic::binary-size(4), rest::binary>> = @basis_reply
      assert {:error, :bad_reply} = BasisQuery.decode_reply(<<head, 0::32, rest::binary>>, 0xBEEF)

      assert {:error, :bad_reply} =
               BasisQuery.decode_reply(binary_part(@basis_reply, 0, 20), 0xBEEF)
    end

    test "a probe reads a server that answers, and times out on one that does not" do
      {:ok, answering} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(answering)

      Task.start(fn ->
        {:ok, {ip, from, query}} = :gen_udp.recv(answering, 0, 5_000)
        <<8, _magic::little-32, _v::little-16, nonce::little-16, _::binary>> = query

        <<h, m::binary-size(4), v::binary-size(2), _old::binary-size(2), body::binary>> =
          @basis_reply

        :gen_udp.send(
          answering,
          ip,
          from,
          <<h, m::binary, v::binary, nonce::little-16, body::binary>>
        )
      end)

      assert {:ok, %{name: "main basis server", online: 1}} =
               BasisQuery.probe("127.0.0.1", port, 2_000)

      {:ok, silent} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, silent_port} = :inet.port(silent)
      assert {:error, :timeout} = BasisQuery.probe("127.0.0.1", silent_port, 300)
    end
  end

  describe "Overte directory" do
    @places %{
      "status" => "success",
      "data" => %{
        "places" => [
          %{
            "name" => "hytrion",
            "address" => "24.202.187.185:42102/0,0,0/0,0,0,1",
            "description" => "A town",
            "maturity" => "everyone",
            "visibility" => "open",
            "domain" => %{
              "id" => "d-1",
              "name" => "Hytrion",
              "active" => true,
              "num_users" => 3,
              "capacity" => 12,
              "network_address" => "24.202.187.185",
              "network_port" => 42_102,
              "time_of_last_heartbeat" => "2026-10-10T18:40:43.155Z"
            }
          },
          %{
            "name" => "Hytrion-Junction",
            "address" => "24.202.187.185:42102/1,2,3/0,0,0,1",
            "maturity" => "everyone",
            "visibility" => "open",
            "domain" => %{
              "id" => "d-1",
              "name" => "Hytrion",
              "active" => true,
              "num_users" => 3,
              "capacity" => 12,
              "network_address" => "24.202.187.185",
              "network_port" => 42_102
            }
          },
          %{
            "name" => "test74",
            "address" => "172.104.202.151:40302/0,0,0/0,0,0,1",
            "maturity" => "unrated",
            "visibility" => "open",
            "domain" => %{
              "id" => "d-2",
              "name" => "test74",
              "active" => false,
              "num_users" => 0,
              "network_address" => "172.104.202.151",
              "network_port" => 40_302
            }
          }
        ]
      }
    }

    test "active domains are listed once each, with their user count and capacity" do
      assert [
               %{
                 platform: "overte",
                 external_id: "d-1",
                 name: "Hytrion",
                 address: "24.202.187.185:42102",
                 online: 3,
                 capacity: 12,
                 motd: "A town"
               }
             ] = OverteDirectory.parse_places(@places)
    end

    test "control: an error body lists nothing" do
      assert [] =
               OverteDirectory.parse_places(%{"status" => "failure", "error" => "Not logged in"})
    end
  end

  describe "polling" do
    setup do
      {:ok, basis} =
        Lobby.upsert_server(%{
          platform: "basis",
          external_id: "server1.basisvr.org:4296",
          address: "server1.basisvr.org:4296",
          name: "server1.basisvr.org",
          client_url: "https://basisvr.org/"
        })

      %{basis: basis}
    end

    test "a poll records a Basis reply and the Overte directory's active domains", %{basis: basis} do
      probes = %{
        basis: fn "server1.basisvr.org", 4296 ->
          {:ok,
           %{name: "main basis server", motd: "another bright day", online: 1, capacity: 5000}}
        end,
        overte: fn -> {:ok, OverteDirectory.parse_places(@places)} end
      }

      :ok = Lobby.poll(probes)

      basis = Lobby.get_server!(basis.id)
      assert %{status: "up", name: "main basis server", online: 1, capacity: 5000} = basis
      assert basis.last_seen_at

      assert [%{platform: "overte", name: "Hytrion", status: "up", online: 3}] =
               Lobby.list_servers("overte")
    end

    test "control: a Basis server that does not answer is marked down and keeps its last name",
         %{basis: basis} do
      probes = %{
        basis: fn _host, _port -> {:error, :timeout} end,
        overte: fn -> {:ok, []} end
      }

      :ok = Lobby.poll(probes)
      assert %{status: "down", name: "server1.basisvr.org"} = Lobby.get_server!(basis.id)
    end

    test "an Overte domain that leaves the directory is marked down" do
      :ok =
        Lobby.poll(%{
          basis: fn _, _ -> {:error, :timeout} end,
          overte: fn -> {:ok, OverteDirectory.parse_places(@places)} end
        })

      :ok = Lobby.poll(%{basis: fn _, _ -> {:error, :timeout} end, overte: fn -> {:ok, []} end})
      assert [%{name: "Hytrion", status: "down"}] = Lobby.list_servers("overte")
    end

    test "the poll interval is ten minutes" do
      assert Uro.Lobby.Poller.interval_ms() == 10 * 60 * 1000
    end
  end

  describe "API" do
    test "the server list is JSON at /api/v1/lobby/servers, with the poll interval" do
      {:ok, _} =
        Lobby.upsert_server(%{
          platform: "basis",
          external_id: "server1.basisvr.org:4296",
          address: "server1.basisvr.org:4296",
          name: "main basis server",
          motd: "another bright day",
          online: 1,
          capacity: 5000,
          status: "up"
        })

      conn = get(build_conn(), "/api/v1/lobby/servers")
      assert conn.status == 200

      assert %{
               "poll_interval_s" => 600,
               "servers" => [
                 %{
                   "platform" => "basis",
                   "address" => "server1.basisvr.org:4296",
                   "name" => "main basis server",
                   "online" => 1,
                   "capacity" => 5000,
                   "status" => "up"
                 }
               ]
             } = Jason.decode!(conn.resp_body)
    end

    test "the list says when the last poll ran and when the next one is due" do
      polled = ~U[2026-10-10 19:00:00Z]
      :ok = Lobby.record_poll(polled)

      conn = get(build_conn(), "/api/v1/lobby/servers")

      assert %{
               "polled_at" => "2026-10-10T19:00:00Z",
               "next_poll_at" => "2026-10-10T19:10:00Z"
             } = Jason.decode!(conn.resp_body)
    end

    test "control: before the first poll there is no due time to count down to" do
      :ok = Lobby.record_poll(nil)
      conn = get(build_conn(), "/api/v1/lobby/servers")
      assert %{"polled_at" => nil, "next_poll_at" => nil} = Jason.decode!(conn.resp_body)
    end

    test "a poll records its own time" do
      :ok = Lobby.record_poll(nil)
      :ok = Lobby.poll(%{basis: fn _, _ -> {:error, :timeout} end, overte: fn -> {:ok, []} end})
      assert %DateTime{} = Lobby.last_poll()
    end

    test "the API server keeps its health check at / and /health; the frontend owns the page" do
      for path <- ["/", "/health"] do
        conn = get(build_conn(), path)
        assert %{"services" => %{"uro" => "healthy"}} = Jason.decode!(conn.resp_body)
      end
    end
  end
end

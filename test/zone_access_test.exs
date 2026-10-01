# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule Uro.ZoneAccessTest do
  use Uro.RepoCase

  alias Uro.VSekai
  alias Uro.VSekai.Zone

  # The time is taken at insert, not at compile: a zone stops being fresh 30 s later.
  defp fresh_zone(attrs) do
    Repo.insert!(%Zone{last_put_at: DateTime.utc_now()} |> Map.merge(attrs))
  end

  describe "can_enter_zone?/2" do
    test "public zone admits any player" do
      zone = %Zone{public: true, user_id: "owner-1"}
      assert VSekai.can_enter_zone?(zone, "random-player")
    end

    test "private zone admits owner" do
      zone = %Zone{public: false, user_id: "owner-1", id: "zone-1"}
      assert VSekai.can_enter_zone?(zone, "owner-1")
    end

    test "private zone denies stranger" do
      zone = %Zone{public: false, user_id: "owner-1", id: "zone-1"}
      refute VSekai.can_enter_zone?(zone, "stranger-2")
    end
  end

  describe "list_fresh_zones/0" do
    test "returns only public zones" do
      fresh_zone(%{
        public: true,
        status: "public",
        address: "1.2.3.4",
        port: 7443,
        map: "map-pub",
        name: "pub"
      })

      fresh_zone(%{
        public: false,
        status: "private",
        address: "1.2.3.5",
        port: 7443,
        map: "map-priv",
        name: "priv"
      })

      zones = VSekai.list_fresh_zones()
      assert Enum.all?(zones, & &1.public)
    end
  end

  describe "list_fresh_zones/1 with user_id" do
    test "returns public zones and owner private zones" do
      import Ecto.Changeset
      me_user = Repo.insert!(%Uro.Accounts.User{} |> cast(%{email: "me@test.test"}, [:email]))

      other_user =
        Repo.insert!(%Uro.Accounts.User{} |> cast(%{email: "other@test.test"}, [:email]))

      me = me_user.id
      other = other_user.id

      fresh_zone(%{
        public: true,
        status: "public",
        address: "1.2.3.4",
        port: 7443,
        map: "map-pub",
        name: "pub"
      })

      fresh_zone(%{
        public: false,
        status: "private",
        address: "1.2.3.5",
        port: 7443,
        map: "map-mine",
        name: "mine",
        user_id: me
      })

      fresh_zone(%{
        public: false,
        status: "private",
        address: "1.2.3.6",
        port: 7443,
        map: "map-other",
        name: "other",
        user_id: other
      })

      zones = VSekai.list_fresh_zones(user_id: me)
      names = Enum.map(zones, & &1.name)
      assert "pub" in names
      assert "mine" in names
      refute "other" in names
    end
  end
end

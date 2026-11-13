# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.TuplesTest do
  @moduledoc """
  `Uro.Tuples` stores relationship tuples, one row for each (subject, verb, object).

  The controls are the malformed tuples (an empty subject, verb or object is refused with
  `{:error, changeset}` and leaves no row) and the count of rows after a tuple is granted
  twice.

  The epoch of an object is in its own row of `tuple_epochs`, so the tests under "an epoch
  never repeats" delete every tuple of an object and then replace again: the second
  replace must give an epoch the object never had. The last test runs the migration down
  and up over rows that have epochs, and checks that each object gets its highest one.
  """
  use Uro.RepoCase, async: false

  alias Uro.Tuples
  alias Uro.Tuples.Epoch
  alias Uro.Tuples.Tuple

  @epoch_migration {20_261_113_000_001, Uro.Repo.Migrations.CreateTupleEpochs,
                    "priv/repo/migrations/20261113000001_create_tuple_epochs.exs"}

  defp rows, do: Repo.aggregate(Tuple, :count)

  test "a tuple that was put is there, and one that was not is not" do
    refute Tuples.has?("alice", "CONTROLS", "ball-7")

    assert {:ok, %Tuple{subject: "alice", verb: "CONTROLS", object: "ball-7", epoch: 0}} =
             Tuples.put("alice", "CONTROLS", "ball-7")

    assert Tuples.has?("alice", "CONTROLS", "ball-7")
    refute Tuples.has?("bob", "CONTROLS", "ball-7")
    refute Tuples.has?("alice", "OWNS", "ball-7")
    refute Tuples.has?("alice", "CONTROLS", "ball-8")
  end

  test "a verb given as an atom is stored as its string" do
    assert {:ok, %Tuple{verb: "OWNS"}} = Tuples.put("alice", :OWNS, "zone-1")
    assert Tuples.has?("alice", "OWNS", "zone-1")
    assert Tuples.has?("alice", :OWNS, "zone-1")
  end

  test "control: granting twice leaves one row and returns the same row" do
    {:ok, first} = Tuples.put("alice", "CONTROLS", "ball-7")
    {:ok, second} = Tuples.put("alice", "CONTROLS", "ball-7")

    assert second.id == first.id
    assert rows() == 1
  end

  test "control: the unique index refuses a second row for the same tuple" do
    row = %Tuple{subject: "alice", verb: "CONTROLS", object: "ball-7"}
    Repo.insert!(row)
    assert_raise Ecto.ConstraintError, fn -> Repo.insert!(row) end
  end

  test "control: an empty subject, verb or object is refused and leaves no row" do
    for {subject, verb, object} <- [
          {"", "CONTROLS", "ball-7"},
          {"alice", "", "ball-7"},
          {"alice", "CONTROLS", ""},
          {nil, "CONTROLS", "ball-7"},
          {"alice", nil, "ball-7"}
        ] do
      assert {:error, %Ecto.Changeset{valid?: false}} = Tuples.put(subject, verb, object)
    end

    assert rows() == 0
  end

  test "delete removes the one tuple and says how many rows went" do
    {:ok, _} = Tuples.put("alice", "CONTROLS", "ball-7")
    {:ok, _} = Tuples.put("bob", "CONTROLS", "ball-8")

    assert Tuples.delete("alice", "CONTROLS", "ball-7") == {:ok, 1}
    refute Tuples.has?("alice", "CONTROLS", "ball-7")
    assert Tuples.has?("bob", "CONTROLS", "ball-8")
    assert Tuples.delete("alice", "CONTROLS", "ball-7") == {:ok, 0}
  end

  test "list_for_object gives every tuple of the object and no other" do
    {:ok, _} = Tuples.put("alice", "CONTROLS", "ball-7")
    {:ok, _} = Tuples.put("bob", "SEES", "ball-7")
    {:ok, _} = Tuples.put("bob", "CONTROLS", "ball-8")

    listed = for t <- Tuples.list_for_object("ball-7"), do: {t.subject, t.verb, t.object}
    assert Enum.sort(listed) == [{"alice", "CONTROLS", "ball-7"}, {"bob", "SEES", "ball-7"}]
    assert Tuples.list_for_object("ball-9") == []
  end

  describe "replace/3 and epoch/1" do
    test "an object with no tuple has epoch 0, and a put does not raise it" do
      assert Tuples.epoch("ball-7") == 0
      {:ok, _} = Tuples.put("alice", "CONTROLS", "ball-7")
      assert Tuples.epoch("ball-7") == 0
    end

    test "replace moves control to the new subject and raises the epoch by exactly one" do
      {:ok, _} = Tuples.put("alice", "CONTROLS", "ball-7")

      assert {:ok, %Tuple{subject: "bob", verb: "CONTROLS", object: "ball-7", epoch: 1}} =
               Tuples.replace("CONTROLS", "ball-7", "bob")

      refute Tuples.has?("alice", "CONTROLS", "ball-7")
      assert Tuples.has?("bob", "CONTROLS", "ball-7")
      assert Tuples.epoch("ball-7") == 1

      for {subject, epoch} <- [{"carol", 2}, {"alice", 3}, {"alice", 4}] do
        assert {:ok, %Tuple{epoch: ^epoch}} = Tuples.replace("CONTROLS", "ball-7", subject)
        assert Tuples.epoch("ball-7") == epoch
        assert [%Tuple{subject: ^subject}] = Tuples.list_for_object("ball-7")
      end
    end

    test "replace removes every holder of the verb and touches no other verb or object" do
      for subject <- ~w(alice carol), do: {:ok, _} = Tuples.put(subject, "CONTROLS", "ball-7")
      {:ok, _} = Tuples.put("alice", "SEES", "ball-7")
      {:ok, _} = Tuples.put("alice", "CONTROLS", "ball-8")

      {:ok, _} = Tuples.replace("CONTROLS", "ball-7", "bob")

      listed = for t <- Tuples.list_for_object("ball-7"), do: {t.subject, t.verb, t.epoch}
      assert Enum.sort(listed) == [{"alice", "SEES", 0}, {"bob", "CONTROLS", 1}]
      assert Tuples.has?("alice", "CONTROLS", "ball-8")
      assert Tuples.epoch("ball-8") == 0
    end

    test "control: a replace with an empty subject is refused and changes nothing" do
      {:ok, _} = Tuples.put("alice", "CONTROLS", "ball-7")

      assert {:error, %Ecto.Changeset{valid?: false}} = Tuples.replace("CONTROLS", "ball-7", "")
      assert Tuples.has?("alice", "CONTROLS", "ball-7")
      assert Tuples.epoch("ball-7") == 0
    end
  end

  describe "an epoch never repeats" do
    test "a replace after every tuple of the object was deleted gives the next epoch" do
      {:ok, _} = Tuples.put("alice", "CONTROLS", "ball-7")
      {:ok, first} = Tuples.replace("CONTROLS", "ball-7", "alice")

      assert Tuples.delete("alice", "CONTROLS", "ball-7") == {:ok, 1}
      assert Tuples.list_for_object("ball-7") == []
      after_delete = Tuples.epoch("ball-7")

      {:ok, second} = Tuples.replace("CONTROLS", "ball-7", "bob")

      assert [first.epoch, second.epoch] == [1, 2]
      assert [after_delete, Tuples.epoch("ball-7")] == [1, 2]
    end

    test "each object has one epoch row, and a replace of one verb raises it for the object" do
      assert {:ok, %Tuple{epoch: 1}} = Tuples.replace("CONTROLS", "ball-7", "alice")
      assert {:ok, %Tuple{epoch: 2}} = Tuples.replace("SEES", "ball-7", "bob")
      assert {:ok, %Tuple{epoch: 1}} = Tuples.replace("CONTROLS", "ball-8", "alice")

      stored = for e <- Repo.all(Epoch), do: {e.object, e.epoch}
      assert Enum.sort(stored) == [{"ball-7", 2}, {"ball-8", 1}]
    end

    test "control: put, delete and a refused replace make no epoch row and raise none" do
      {:ok, _} = Tuples.put("alice", "CONTROLS", "ball-7")
      {:ok, 1} = Tuples.delete("alice", "CONTROLS", "ball-7")
      assert {:error, %Ecto.Changeset{}} = Tuples.replace("CONTROLS", "ball-7", "")
      assert {:error, %Ecto.Changeset{}} = Tuples.replace("CONTROLS", "", "alice")
      assert {:error, %Ecto.Changeset{}} = Tuples.replace("", "ball-7", "alice")
      assert Repo.aggregate(Epoch, :count) == 0

      {:ok, _} = Tuples.replace("CONTROLS", "ball-7", "alice")
      assert {:error, %Ecto.Changeset{}} = Tuples.replace("CONTROLS", "ball-7", "")
      assert Tuples.epoch("ball-7") == 1
      assert Tuples.has?("alice", "CONTROLS", "ball-7")
    end

    test "the migration gives each object the highest epoch among its rows, and goes down" do
      {version, module, path} = @epoch_migration
      Code.ensure_loaded?(module) or Code.require_file(path)

      :ok = Ecto.Migrator.down(Repo, version, module, log: false)
      assert_raise Exqlite.Error, fn -> Repo.query!("SELECT 1 FROM tuple_epochs") end

      for {subject, verb, object, epoch} <- [
            {"alice", "CONTROLS", "ball-7", 3},
            {"bob", "SEES", "ball-7", 5},
            {"carol", "SEES", "ball-7", 0},
            {"alice", "CONTROLS", "ball-8", 1},
            {"alice", "CONTROLS", "ball-9", 0}
          ] do
        Repo.insert!(%Tuple{subject: subject, verb: verb, object: object, epoch: epoch})
      end

      :ok = Ecto.Migrator.up(Repo, version, module, log: false)

      assert Enum.map(~w(ball-7 ball-8 ball-9 ball-10), &Tuples.epoch/1) == [5, 1, 0, 0]
      assert {:ok, %Tuple{epoch: 6}} = Tuples.replace("CONTROLS", "ball-7", "bob")
      assert {:ok, %Tuple{epoch: 1}} = Tuples.replace("CONTROLS", "ball-9", "bob")
    end
  end
end

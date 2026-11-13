# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.TuplesTest do
  @moduledoc """
  `Uro.Tuples` stores relationship tuples, one row for each (subject, verb, object).

  The controls are the malformed tuples (an empty subject, verb or object is refused with
  `{:error, changeset}` and leaves no row) and the count of rows after a tuple is granted
  twice.
  """
  use Uro.RepoCase, async: false

  alias Uro.Tuples
  alias Uro.Tuples.Tuple

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
end

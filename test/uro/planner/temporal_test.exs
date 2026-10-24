# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.TemporalTest do
  @moduledoc """
  Verification for the plain-Elixir port of `standalone/tw_temporal.hpp`
  (RFD66606-0028).
  """
  use ExUnit.Case, async: true

  alias Uro.Planner.Temporal

  describe "parse_duration_ms/1" do
    test "plain minutes" do
      assert Temporal.parse_duration_ms("PT10M") == {:ok, 10 * 60 * 1000}
    end

    test "bare P is zero duration" do
      assert Temporal.parse_duration_ms("P") == {:ok, 0}
    end

    test "combined date and time components, canonical order" do
      assert Temporal.parse_duration_ms("P1Y2M3DT4H5M6S") ==
               {:ok,
                1 * 365 * 86_400 * 1000 + 2 * 30 * 86_400 * 1000 + 3 * 86_400 * 1000 +
                  4 * 3600 * 1000 + 5 * 60 * 1000 + 6 * 1000}
    end

    test "fractional seconds" do
      assert Temporal.parse_duration_ms("PT1.5S") == {:ok, 1500}
    end

    test "weeks stand alone" do
      assert Temporal.parse_duration_ms("P1W") == {:ok, 7 * 86_400 * 1000}
    end

    test "weeks mixed with anything else is an error" do
      assert Temporal.parse_duration_ms("P1WT1H") == :error
      assert Temporal.parse_duration_ms("P1W1D") == :error
    end

    test "non-canonical order is an error" do
      assert Temporal.parse_duration_ms("P2M1Y") == :error
    end

    test "fraction not on the lowest-order unit is an error" do
      assert Temporal.parse_duration_ms("PT1.5H6S") == :error
    end

    test "malformed input" do
      assert Temporal.parse_duration_ms("") == :error
      assert Temporal.parse_duration_ms("PT") == :error
      assert Temporal.parse_duration_ms("garbage") == :error
    end
  end

  describe "format_duration_ms/1" do
    test "round-trips plain minutes" do
      assert Temporal.format_duration_ms(10 * 60 * 1000) == "PT10M"
    end

    test "zero is PT0S" do
      assert Temporal.format_duration_ms(0) == "PT0S"
    end

    test "fractional seconds trim trailing zeros" do
      assert Temporal.format_duration_ms(1500) == "PT1.5S"
      assert Temporal.format_duration_ms(1000) == "PT1S"
    end

    test "hours and minutes without seconds" do
      assert Temporal.format_duration_ms(3600_000 + 120_000) == "PT1H2M"
    end
  end

  describe "check/3 (sequential STN)" do
    test "empty plan" do
      assert Temporal.check([], %{}) == %{
               consistent: true,
               total: "PT0S",
               origin: "PT0S",
               steps: []
             }
    end

    test "two sequential actions accumulate start/end times" do
      result = Temporal.check(["a", "b"], %{"a" => "PT10M", "b" => "PT5M"})

      assert result.consistent
      assert result.total == "PT15M"

      assert result.steps == [
               %{action: "a", duration: "PT10M", start: "PT0S", end: "PT10M"},
               %{action: "b", duration: "PT5M", start: "PT10M", end: "PT15M"}
             ]
    end

    test "an action with no duration entry defaults to PT0S" do
      result = Temporal.check(["a"], %{})
      assert result.steps == [%{action: "a", duration: "PT0S", start: "PT0S", end: "PT0S"}]
    end

    test "origin offset shifts every step" do
      result = Temporal.check(["a"], %{"a" => "PT10M"}, "PT1H")
      assert result.steps == [%{action: "a", duration: "PT10M", start: "PT1H", end: "PT1H10M"}]
    end
  end

  describe "civil-calendar duration" do
    test "P1M from Jan 31 in a leap year clamps to Feb 29" do
      {:ok, cursor} = Date.new(2024, 1, 31)
      assert {:ok, ms, new_cursor} = Temporal.civil_duration_ms("P1M", cursor)
      assert new_cursor == ~D[2024-02-29]
      assert ms == 29 * 86_400 * 1000
    end

    test "P1Y from a leap-year date counts 366 days" do
      {:ok, cursor} = Date.new(2024, 1, 1)
      assert {:ok, ms, new_cursor} = Temporal.civil_duration_ms("P1Y", cursor)
      assert new_cursor == ~D[2025-01-01]
      assert ms == 366 * 86_400 * 1000
    end

    test "check_civil/4 falls back to fixed-day arithmetic with no reference date" do
      fixed = Temporal.check(["a"], %{"a" => "P1M"})
      civil = Temporal.check_civil(["a"], %{"a" => "P1M"}, "PT0S", nil)
      assert fixed == civil
    end

    test "check_civil/4 uses calendar arithmetic with a reference date" do
      result = Temporal.check_civil(["a"], %{"a" => "P1M"}, "PT0S", "2024-01-31")
      assert result.steps == [%{action: "a", duration: "P1M", start: "PT0S", end: "PT696H"}]
    end
  end
end

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.HRRTest do
  @moduledoc """
  Verification for the plain-Elixir port of `standalone/tw_hrr.hpp`
  (RFD66606-0032). No golden byte-vector from the Python/C++ originals is
  vendored here -- instead these tests verify the HRR algebra's own
  defining properties (deterministic, dimension-correct, phases in
  [0, 2*pi), bind/unbind are inverses, bundle similarity ~= 1/N,
  round-trip serialization), which any faithful port must satisfy
  regardless of host language.
  """
  use ExUnit.Case, async: true

  alias Uro.Planner.HRR

  @two_pi 6.283185307179586

  describe "encode_atom/2" do
    test "is deterministic for the same word and dim" do
      assert HRR.encode_atom("cat", 64) == HRR.encode_atom("cat", 64)
    end

    test "differs for different words" do
      refute HRR.encode_atom("cat", 64) == HRR.encode_atom("dog", 64)
    end

    test "returns exactly dim phases, each in [0, 2*pi)" do
      phases = HRR.encode_atom("cat", 100)
      assert length(phases) == 100
      assert Enum.all?(phases, &(&1 >= 0.0 and &1 < @two_pi))
    end
  end

  describe "bind/2 and unbind/2" do
    test "unbind is the inverse of bind" do
      a = HRR.encode_atom("red", 64)
      b = HRR.encode_atom("apple", 64)
      bound = HRR.bind(a, b)
      recovered = HRR.unbind(bound, b)

      Enum.zip(a, recovered)
      |> Enum.each(fn {expected, actual} ->
        assert_in_delta expected, actual, 1.0e-9
      end)
    end
  end

  describe "bundle/1 and similarity/2" do
    test "an empty bundle is an empty vector" do
      assert HRR.bundle([]) == []
    end

    test "self-similarity is 1.0" do
      v = HRR.encode_atom("cat", 64)
      assert_in_delta HRR.similarity(v, v), 1.0, 1.0e-9
    end

    test "similarity of an empty vector is 0.0" do
      assert HRR.similarity([], []) == 0.0
    end

    test "a bundled component is much more similar to the bundle than an unrelated atom is" do
      vecs = for w <- ["a", "b", "c", "d"], do: HRR.encode_atom(w, 4096)
      bundled = HRR.bundle(vecs)
      unrelated = HRR.encode_atom("unrelated", 4096)
      baseline = HRR.similarity(unrelated, bundled)

      Enum.each(vecs, fn v ->
        sim = HRR.similarity(v, bundled)
        assert sim > baseline + 0.1
      end)
    end
  end

  describe "snr_estimate/2" do
    test "returns sqrt(dim / n_items)" do
      assert_in_delta HRR.snr_estimate(4096, 4), 32.0, 1.0e-9
    end

    test "returns a very large sentinel when n_items <= 0" do
      assert HRR.snr_estimate(4096, 0) == 1.0e18
    end
  end

  describe "tokenize/1" do
    test "lowercases, splits on whitespace, and strips punctuation" do
      assert HRR.tokenize("The Cat, sat! (on the mat).") ==
               ["the", "cat", "sat", "on", "the", "mat"]
    end
  end

  describe "encode_text/2" do
    test "an empty string still yields a full-dimension vector" do
      phases = HRR.encode_text("", 64)
      assert length(phases) == 64
    end

    test "is deterministic and order-independent for a bag of words" do
      a = HRR.encode_text("cat sat mat", 64)
      b = HRR.encode_text("mat cat sat", 64)

      Enum.zip(a, b)
      |> Enum.each(fn {x, y} -> assert_in_delta x, y, 1.0e-9 end)
    end
  end

  describe "encode_binding/3" do
    test "unbind(encode_binding(content, entity), encode_atom(entity)) == encode_text(content)" do
      content = "the sky is blue"
      entity = "Weather"
      dim = 64

      bound = HRR.encode_binding(content, entity, dim)
      recovered = HRR.unbind(bound, HRR.encode_atom(String.downcase(entity), dim))
      expected = HRR.encode_text(content, dim)

      Enum.zip(expected, recovered)
      |> Enum.each(fn {e, r} -> assert_in_delta e, r, 1.0e-9 end)
    end
  end

  describe "phases_to_bytes/1 and bytes_to_phases/1" do
    test "round-trips exactly" do
      phases = HRR.encode_atom("roundtrip", 32)
      assert HRR.bytes_to_phases(HRR.phases_to_bytes(phases)) == phases
    end

    test "produces 8 bytes per phase" do
      phases = HRR.encode_atom("x", 10)
      assert byte_size(HRR.phases_to_bytes(phases)) == 80
    end
  end
end

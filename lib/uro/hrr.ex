# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Hrr do
  @moduledoc """
  Pure-Elixir Holographic Reduced Representation / Vector Symbolic
  Architecture primitives (Plate 1995; bipolar MAP-B variant, per Kanerva
  2009's survey of VSA families).

  No NIF, no cross-language boundary. A separate phase-based HRR exists
  as `Uro.Planner.HRR` (RFD66606-0032, ported from the now-retired
  `standalone/tw_hrr.hpp`) for planner fact retrieval -- that module's
  algebra is deliberately not reused here, since this one is bipolar
  MAP-B, a different VSA family for a different purpose (semantic
  tagging, not retrieval scoring). A Lean4-verified core
  (`openusd-fabric/lean/Fabric/HRR.lean`, same algorithm, fixed-point) was
  built first and stays as a real, independently-verified artifact, but
  routing zone-backend through it would need a NIF bridge with no working
  precedent in this org. Plain Elixir is the simplest thing that's
  actually correct: real circular-convolution `bind`, not the pointwise
  `+`/`-` `weft-warp-loop`'s `taskweft-hrr.shrub` port used.

  Vectors are plain lists of `@dim` floats, each an ordinary Elixir float
  -- no fixed-point scaling needed here (that convention exists for the
  org's formally-verified, cross-platform-bit-exact Lean kernels; this is
  an application-level tagging feature, not one of those).
  """

  import Bitwise

  @dim 512

  @doc "Vector dimension every HRR vector in this module has."
  def dim, do: @dim

  @doc """
  Deterministic seeded bipolar atomic vector: one component per
  splitmix64 draw, each `±1.0` keyed off the draw's low bit. Same `seed`
  always yields the same atom -- the item-memory generator every semantic
  tag's vector comes from (see `Uro.Tagging.atom_seed/2`).
  """
  def gen_atom(seed) when is_integer(seed) do
    {atom, _final_state} =
      Enum.map_reduce(1..@dim, seed, fn _, state ->
        {z, state2} = splitmix64_step(state)
        component = if (z &&& 1) == 0, do: -1.0, else: 1.0
        {component, state2}
      end)

    atom
  end

  defp splitmix64_step(state) do
    state = mask64(state + 0x9E3779B97F4A7C15)
    z = state
    z = mask64(bxor(z, z >>> 30) * 0xBF58476D1CE4E5B9)
    z = mask64(bxor(z, z >>> 27) * 0x94D049BB133111EB)
    z = bxor(z, z >>> 31)
    {z, state}
  end

  defp mask64(x), do: x &&& 0xFFFFFFFFFFFFFFFF

  @doc """
  Circular convolution. `bind`'s defining property is that the result is
  dissimilar to both inputs, so a bound (role, filler) pair can be summed
  into a superposed memory without the pair itself swamping either
  operand.
  """
  def bind(a, b) when length(a) == length(b) do
    d = length(a)
    av = List.to_tuple(a)
    bv = List.to_tuple(b)

    for i <- 0..(d - 1) do
      Enum.reduce(0..(d - 1), 0.0, fn k, acc ->
        j = rem(i + d - k, d)
        acc + elem(av, k) * elem(bv, j)
      end)
    end
  end

  @doc "Involution: `v` reversed around index 0 (`v[(-i) mod d]`)."
  def involution(v) do
    d = length(v)
    vv = List.to_tuple(v)
    for i <- 0..(d - 1), do: elem(vv, rem(d - i, d))
  end

  @doc """
  Circular correlation: approximately recovers `memory` from
  `bind(memory, key)` given `key`. Approximate, not exact -- unlike the
  fake pointwise `+`/`-` port this replaces, this is a real similarity
  bound, not an equality.
  """
  def unbind(c, k), do: bind(c, involution(k))

  @doc """
  Superposition: elementwise sum. Unlike `bind`, the result stays similar
  to both inputs -- this is what lets many tag atoms combine into one
  fixed-size asset vector.
  """
  def bundle(a, b), do: Enum.zip_with(a, b, &(&1 + &2))

  @doc "Cosine similarity in [-1.0, 1.0]. 0.0 if either vector is all-zero."
  def cosine_sim(a, b) do
    {dot, sum_a2, sum_b2} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {d, sa, sb} ->
        {d + x * y, sa + x * x, sb + y * y}
      end)

    denom = :math.sqrt(sum_a2) * :math.sqrt(sum_b2)
    if denom == 0.0, do: 0.0, else: dot / denom
  end
end

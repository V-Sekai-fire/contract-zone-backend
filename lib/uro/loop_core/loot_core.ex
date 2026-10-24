# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.LoopCore.LootCore do
  @moduledoc """
  Hand-ported from `v-sekai-multiplayer-fabric/loot`'s Lean core (via
  `c_src/guest/content/loot.scm`'s own translation) into plain, idiomatic
  Elixir -- not compiled/sandboxed, per the revised RFD66606-0026/0027: this
  is fully-trusted, team-authored game logic, not untrusted content, so
  it runs as ordinary Elixir rather than through the RISC-V sandbox.

  RNG: Lean's `UInt32` arithmetic wraps automatically (mod 2^32); Elixir
  integers are arbitrary-precision, so every operation that could exceed
  32 bits is explicitly masked with `u32/1` to reproduce that wraparound
  -- matching `loot.scm`'s own documented reasoning bit-for-bit.
  """
  import Bitwise

  @mask 0xFFFFFFFF

  defp u32(x), do: x &&& @mask

  defp xorshift32_next32(s) do
    s = u32(bxor(s, u32(s <<< 13)))
    s = u32(bxor(s, s >>> 17))
    u32(bxor(s, u32(s <<< 5)))
  end

  defp rng_range(_seed, 0), do: 0
  defp rng_range(seed, bound), do: rem(xorshift32_next32(seed), bound)

  defp total_weight(table), do: Enum.reduce(table, 0, fn {_item, w}, acc -> acc + w end)

  defp pick([], _r, _acc), do: 0

  defp pick([{item, w} | rest], r, acc) do
    new_acc = acc + w
    if r < new_acc, do: item, else: pick(rest, r, new_acc)
  end

  @doc """
  `loot-roll(seed, table)` -- `table` is a list of `{item, weight}`
  tuples. Golden vector: `roll(42, [{1,10},{2,20},{3,5}]) == 3`.
  """
  @spec roll(integer(), [{term(), non_neg_integer()}]) :: term()
  def roll(seed, table) do
    case total_weight(table) do
      0 -> 0
      tot -> pick(table, rng_range(seed, tot), 0)
    end
  end
end

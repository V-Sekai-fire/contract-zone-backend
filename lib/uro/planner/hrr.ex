# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.HRR do
  @moduledoc """
  Hand-ported from `standalone/tw_hrr.hpp` (Holographic Reduced
  Representations, Plate 1995 / Gayler 2004) into plain Elixir --
  same reasoning as the other RFD66606-0026/0028/0029/0030 ports: no
  untrusted content, no sandbox needed. Atoms are deterministic
  SHA-256-derived phase vectors, matching the original's Python/C++
  implementations byte-for-byte (same SHA-256, same little-endian
  uint16 phase derivation, same circular-mean bundle).

  Unlike the C++ original, this module does NOT hand-roll SHA-256 --
  the BEAM's `:crypto.hash/2` already provides it, and Elixir's binary
  pattern-matching already provides little-endian uint16/float64
  packing/unpacking, so those two ~90-line C++ sections (`_sha256`,
  `phases_to_bytes`/`bytes_to_phases`) collapse to a few lines each
  with no loss of fidelity -- both are pinned to public standards
  (FIPS 180-4, IEEE 754), not project-specific behavior.
  """

  @two_pi 6.283185307179586
  @default_dim 4096
  @values_per_block 16

  @type phase_vec :: [float()]

  @doc "Deterministic atom: SHA-256 counter blocks -> phases in [0, 2*pi)."
  @spec encode_atom(String.t(), pos_integer()) :: phase_vec()
  def encode_atom(word, dim \\ @default_dim) do
    blocks_needed = div(dim + @values_per_block - 1, @values_per_block)

    0..(blocks_needed - 1)
    |> Enum.flat_map(fn i ->
      digest = :crypto.hash(:sha256, "#{word}:#{i}")

      for <<val::little-unsigned-16 <- digest>> do
        val * (@two_pi / 65_536.0)
      end
    end)
    |> Enum.take(dim)
  end

  @doc "Circular convolution: element-wise phase addition mod 2*pi."
  @spec bind(phase_vec(), phase_vec()) :: phase_vec()
  def bind(a, b) do
    Enum.zip_with(a, b, fn ai, bi -> phase_mod(ai + bi) end)
  end

  @doc "Circular correlation: element-wise phase subtraction mod 2*pi."
  @spec unbind(phase_vec(), phase_vec()) :: phase_vec()
  def unbind(memory, key) do
    Enum.zip_with(memory, key, fn m, k -> phase_mod(m - k) end)
  end

  defp phase_mod(x) do
    r = :math.fmod(x, @two_pi)
    if r < 0.0, do: r + @two_pi, else: r
  end

  @doc """
  Superposition via circular mean (unit complex vector mean): each
  component e^(i*theta) is a unit phasor, and the mean phasor
  direction atan2(sum sin, sum cos) is the correct superposition for
  retrieval (similarity(v_k, bundle([v1..vN])) ~= 1/N when v_k is one
  of the N components).
  """
  @spec bundle([phase_vec()]) :: phase_vec()
  def bundle([]), do: []

  def bundle(vecs) do
    dim = vecs |> hd() |> length()

    {sum_sin, sum_cos} =
      Enum.reduce(vecs, {List.duplicate(0.0, dim), List.duplicate(0.0, dim)}, fn v,
                                                                                 {ssin, scos} ->
        {Enum.zip_with(ssin, v, fn s, theta -> s + :math.sin(theta) end),
         Enum.zip_with(scos, v, fn c, theta -> c + :math.cos(theta) end)}
      end)

    Enum.zip_with(sum_sin, sum_cos, fn s, c ->
      theta = :math.atan2(s, c)
      if theta < 0.0, do: theta + @two_pi, else: theta
    end)
  end

  @doc "Phase cosine similarity: mean(cos(a - b)) in [-1, 1]."
  @spec similarity(phase_vec(), phase_vec()) :: float()
  def similarity([], _b), do: 0.0

  def similarity(a, b) do
    sum = Enum.zip_with(a, b, fn ai, bi -> :math.cos(ai - bi) end) |> Enum.sum()
    sum / length(a)
  end

  @doc "SNR estimate for storage capacity: sqrt(dim / n_items)."
  @spec snr_estimate(pos_integer(), integer()) :: float()
  def snr_estimate(_dim, n_items) when n_items <= 0, do: 1.0e18
  def snr_estimate(dim, n_items), do: :math.sqrt(dim / n_items)

  @punct_chars String.graphemes(".,!?;:\"'()[]{}-")

  @doc "Tokenise: lowercase + split on whitespace + strip punctuation."
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&strip_punct/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_punct(word) do
    word
    |> String.graphemes()
    |> Enum.drop_while(&(&1 in @punct_chars))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in @punct_chars))
    |> Enum.reverse()
    |> Enum.join()
  end

  @doc "Bag-of-words: bundle of token atom vectors."
  @spec encode_text(String.t(), pos_integer()) :: phase_vec()
  def encode_text(text, dim \\ @default_dim) do
    case tokenize(text) do
      [] -> encode_atom("__hrr_empty__", dim)
      tokens -> tokens |> Enum.map(&encode_atom(&1, dim)) |> bundle()
    end
  end

  @doc """
  Direct content-entity binding: `unbind(encode_binding(c, e), encode_atom(e)) == encode_text(c)`.
  """
  @spec encode_binding(String.t(), String.t(), pos_integer()) :: phase_vec()
  def encode_binding(content, entity, dim \\ @default_dim) do
    bind(encode_text(content, dim), encode_atom(String.downcase(entity), dim))
  end

  @doc "Bundled role encoding."
  @spec encode_fact(String.t(), [String.t()], pos_integer()) :: phase_vec()
  def encode_fact(content, entities, dim \\ @default_dim) do
    role_content = encode_atom("__hrr_role_content__", dim)
    role_entity = encode_atom("__hrr_role_entity__", dim)

    entity_components =
      Enum.map(entities, fn entity ->
        bind(encode_atom(String.downcase(entity), dim), role_entity)
      end)

    bundle([bind(encode_text(content, dim), role_content) | entity_components])
  end

  @doc "Phase vector -> raw bytes (float64 little-endian, 8 bytes/element)."
  @spec phases_to_bytes(phase_vec()) :: binary()
  def phases_to_bytes(phases) do
    for phase <- phases, into: <<>>, do: <<phase::float-little-64>>
  end

  @doc "Raw bytes -> phase vector. Inverse of phases_to_bytes/1."
  @spec bytes_to_phases(binary()) :: phase_vec()
  def bytes_to_phases(data) do
    for <<phase::float-little-64 <- data>>, do: phase
  end
end

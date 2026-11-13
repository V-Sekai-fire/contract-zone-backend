# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Zones.Tables do
  @moduledoc """
  The grant tables of a zone: small binaries that say who may do what.

  The encoders are pure functions from data to bytes. They read no table and call no
  process, so a test in another repository can read exactly the bytes a client would be
  sent. The layouts are in `docs/zone-tables.md`, byte by byte.

  ## Inputs

  `slots` is a list of four entries, one for each slot of the zone (`Uro.Zones.Slots`).
  An empty slot is `nil`. A seated slot is a map:

    * `:user` - the id of the user, as a string;
    * `:number` - the user number (an integer, 0 or more);
    * `:send` - true when the user holds the tuple (user, `SEND`, zone);
    * `:epoch` - the epoch of the user's avatar object.

  `sees` is a set of `{viewer, sender}` pairs of user ids: the viewer holds the tuple
  (viewer, `SEES`, avatar object of the sender). Pairs with a user who is not seated, and
  pairs of a user with itself, are allowed in the set and have no effect.

  ## The router table

  `router_table/2` is for the relay. It is always 20 bytes: four `send` flags, one for
  each slot, then the `sees` matrix of 4 rows by 4 columns in row-major order, where the
  row is the slot of the viewer and the column is the slot of the sender. A cell is 1 when
  both slots are seated, they are different, and the pair is in `sees`. The diagonal is 0.
  The relay must never hold a key, and this function is given none.
  """

  @slots 4

  @type seat :: %{
          user: String.t(),
          number: non_neg_integer(),
          send: boolean(),
          epoch: non_neg_integer()
        }
  @type slots :: [seat() | nil]
  @type sees :: MapSet.t({String.t(), String.t()})
  @type router :: %{send: [boolean()], sees: MapSet.t({0..3, 0..3})}

  @spec router_table(slots(), sees()) :: <<_::160>>
  def router_table(slots, sees) when length(slots) == @slots do
    send = for seat <- slots, into: <<>>, do: <<flag(seat != nil and seat.send)>>

    matrix =
      for viewer <- slots, sender <- slots, into: <<>> do
        <<flag(sees?(viewer, sender, sees))>>
      end

    <<send::binary-size(4), matrix::binary-size(16)>>
  end

  @doc """
  Reads a router table: the four `send` flags by slot, and the set of
  `{viewer slot, sender slot}` pairs that see. A binary that is not 20 bytes, has a byte
  other than 0 or 1, or has a 1 on the diagonal is `{:error, :malformed}`.
  """
  @spec decode_router_table(binary()) :: {:ok, router()} | {:error, :malformed}
  def decode_router_table(<<send::binary-size(4), matrix::binary-size(16)>>) do
    cells = for <<byte <- matrix>>, do: byte
    indexed = Enum.with_index(cells, fn cell, at -> {cell, div(at, @slots), rem(at, @slots)} end)
    flags = :binary.bin_to_list(send)

    if Enum.all?(flags ++ cells, &(&1 in [0, 1])) and
         Enum.all?(indexed, fn {cell, row, column} -> row != column or cell == 0 end) do
      pairs = for {1, row, column} <- indexed, into: MapSet.new(), do: {row, column}
      {:ok, %{send: Enum.map(flags, &(&1 == 1)), sees: pairs}}
    else
      {:error, :malformed}
    end
  end

  def decode_router_table(binary) when is_binary(binary), do: {:error, :malformed}

  defp sees?(nil, _sender, _sees), do: false
  defp sees?(_viewer, nil, _sees), do: false
  defp sees?(%{user: same}, %{user: same}, _sees), do: false
  defp sees?(viewer, sender, sees), do: MapSet.member?(sees, {viewer.user, sender.user})

  defp flag(true), do: 1
  defp flag(false), do: 0
end

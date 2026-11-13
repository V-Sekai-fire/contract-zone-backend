# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Mix.Tasks.Uro.ZoneTables do
  @shortdoc "Writes the grant tables of a zone to a directory"

  @moduledoc """
  Writes the grant tables of a zone (`Uro.Zones.Tables`) to a directory.

      mix uro.zone_tables ZONE_ID DIR [--range OBJECT:FIRST:LAST ...]
      mix uro.zone_tables --fixture DIR [--seed N]

  The files are `router.table`, `member.table`, and `keys.<slot>.table` for each seated
  slot. Their layouts are in `docs/zone-tables.md`. For each file the task prints one line
  with its name, its size and its SHA-256:

      router.table  20 bytes  sha256 2b16...26bf

  `DIR` is made if it is not there. A `keys.<slot>.table` in it for a slot that is not
  seated now is removed, so that a keys file of an earlier run is not handed to a member.
  No other file is removed.

  ## A zone

  With a zone id, the task starts the application and reads the zone from
  `Uro.Zones.Slots`, `Uro.Zones.PairKeys` and the stored tuples
  (`Uro.Zones.Tables.zone_files/2`). A zone id of digits is taken as an integer, as the
  ids of the `zones` table are. `--range` may be given several times; each names an object
  of the tuples and the inclusive range of entity ids it stands for. The object may have
  colons in it.

  The slots and the keys are in the memory of the node that serves the zone. A `mix`
  command starts a node of its own, where nobody is seated, so it writes an empty router
  table, an empty member table and no keys file. To write the tables of a zone that is in
  use, call `Mix.Tasks.Uro.ZoneTables.run/1` or `Uro.Zones.Tables.zone_files/2` in the
  node that serves it.

  If the tables are refused (two ranges share an entity id, or the members changed while
  the task read them) the task stops with the reason and writes nothing.

  ## The fixture

  With `--fixture` the task reads no database and starts nothing. It writes the fixed
  zone of `Uro.Zones.Tables.fixture/1`: four members with the user numbers 7, 9, 12 and
  30 in slots 0 to 3, who all may send and all see each other, at epoch 0. `--seed` (1 by
  default) picks the keys. The same seed always gives the same bytes, so a gate in another
  repository can call the task and compare. The keys of the fixture are public.
  """
  use Mix.Task

  alias Uro.Zones.Tables

  @usage "usage: mix uro.zone_tables ZONE_ID DIR [--range OBJECT:FIRST:LAST ...] | " <>
           "mix uro.zone_tables --fixture DIR [--seed N]"
  @switches [fixture: :boolean, seed: :integer, range: :keep]

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, positional, []} ->
        run(
          Keyword.get(opts, :fixture, false),
          Keyword.get(opts, :seed),
          Keyword.get_values(opts, :range),
          positional
        )

      {_opts, _positional, _invalid} ->
        Mix.raise(@usage)
    end
  end

  defp run(true, seed, [], [dir]) do
    {inputs, keys} = Tables.fixture(seed || 1)
    write(dir, Tables.files(inputs, keys))
  end

  defp run(false, nil, ranges, [zone, dir]) do
    ranges = Enum.map(ranges, &range/1)
    Mix.Task.run("app.start")

    case Tables.zone_files(zone_id(zone), ranges: ranges) do
      {:ok, files} -> write(dir, files)
      {:error, reason} -> Mix.raise("the tables of zone #{zone} were refused: #{inspect(reason)}")
    end
  end

  defp run(_fixture, _seed, _ranges, _positional), do: Mix.raise(@usage)

  defp zone_id(text) do
    case Integer.parse(text) do
      {id, ""} -> id
      _ -> text
    end
  end

  defp range(text) do
    with [last, first | object] when object != [] <- Enum.reverse(String.split(text, ":")),
         {first, ""} <- Integer.parse(first),
         {last, ""} <- Integer.parse(last) do
      {object |> Enum.reverse() |> Enum.join(":"), first, last}
    else
      _ -> Mix.raise("--range takes OBJECT:FIRST:LAST with two integers, not #{inspect(text)}")
    end
  end

  defp write(dir, files) do
    File.mkdir_p!(dir)
    names = Enum.map(files, &elem(&1, 0))

    for slot <- 0..3,
        "keys.#{slot}.table" not in names,
        do: File.rm(Path.join(dir, "keys.#{slot}.table"))

    for {name, bytes} <- files do
      File.write!(Path.join(dir, name), bytes)
      sum = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      Mix.shell().info("#{name}  #{byte_size(bytes)} bytes  sha256 #{sum}")
    end

    :ok
  end
end

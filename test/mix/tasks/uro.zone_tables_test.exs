# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Mix.Tasks.Uro.ZoneTablesFixtureTest do
  @moduledoc """
  `mix uro.zone_tables --fixture`, which another repository's gate calls.

  This case checks out no Repo connection, so a fixture run that read the database would
  fail here. The SHA-256 values are pinned twice: in this test, from a computation made
  outside this code, and in `docs/zone-tables.md`, which the test reads so that the page
  cannot say other values than the task writes.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Uro.ZoneTables
  alias Uro.Zones.Tables

  @names ~w(keys.0.table keys.1.table keys.2.table keys.3.table member.table router.table)
  @sha256 %{
    "keys.0.table" => "5c101b0083c9dadb3c9a5ceb9e8bb0e15f1a1de7a1eda89588854a2e6a54c3aa",
    "keys.1.table" => "71bae1f085920db37678609f3c4a87b075b2bff47556161fe00770453a1dec39",
    "keys.2.table" => "32f6c999857fd1cd85d0d3b040db560cb8da6246fb73d861dd3bf038c71e4562",
    "keys.3.table" => "9157f305739a35b95a1175ef716b86805e13f9ad7c39285f456f288ca6f74dd4",
    "member.table" => "51a2f8087f92fb4099541df54919abacf6340b43db3e9fcc00b258580cf1e9f5",
    "router.table" => "2b16c312ba4e29bd93471fc61c8da7263eed5a3c8306eddcaef9d2fc3f3426bf"
  }

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  defp out_dir do
    dir = Path.join(System.tmp_dir!(), "uro-zone-tables-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      for name <- @names, do: File.rm(Path.join(dir, name))
      File.rmdir(dir)
    end)

    dir
  end

  defp read(dir),
    do: Map.new(File.ls!(dir), fn name -> {name, File.read!(Path.join(dir, name))} end)

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  test "two runs write the same bytes, and they are the documented fixture" do
    [first, second] = for _ <- 1..2, do: out_dir()
    assert ZoneTables.run(["--fixture", first]) == :ok
    assert ZoneTables.run(["--fixture", second]) == :ok

    files = read(first)
    assert Enum.sort(Map.keys(files)) == @names
    assert read(second) == files
    assert Map.new(files, fn {name, bytes} -> {name, sha256(bytes)} end) == @sha256

    page = File.read!("docs/zone-tables.md")
    for {name, sum} <- @sha256, do: assert(page =~ sum, "docs/zone-tables.md lacks #{name}")
  end

  test "the fixture is four members with numbers 7, 9, 12 and 30 who all send and see" do
    dir = out_dir()
    :ok = ZoneTables.run(["--fixture", dir])
    files = read(dir)

    assert files["router.table"] ==
             <<1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0>>

    assert Tables.decode_member_table(files["member.table"]) ==
             {:ok,
              [
                %{first_gid: 2_000_147, last_gid: 2_000_167, slot: 0, epoch: 0},
                %{first_gid: 2_000_189, last_gid: 2_000_209, slot: 1, epoch: 0},
                %{first_gid: 2_000_252, last_gid: 2_000_272, slot: 2, epoch: 0},
                %{first_gid: 2_000_630, last_gid: 2_000_650, slot: 3, epoch: 0}
              ]}

    keys = for slot <- 0..3, into: %{}, do: {slot, decode_keys!(files["keys.#{slot}.table"])}

    for a <- 0..3 do
      assert Map.keys(keys[a]) == Enum.to_list(0..3) -- [a]
      for b <- Map.keys(keys[a]), do: assert(keys[a][b] == keys[b][a])
    end

    all = Enum.uniq(for {_slot, held} <- keys, {_other, key} <- held, do: key)
    assert length(all) == 6

    for key <- all, name <- ~w(router.table member.table) do
      assert :binary.match(files[name], key) == :nomatch, "a key is in #{name}"
    end

    for slot <- 0..3, key <- all -- Map.values(keys[slot]) do
      assert :binary.match(files["keys.#{slot}.table"], key) == :nomatch
    end
  end

  test "it prints each file with its size and its SHA-256" do
    :ok = ZoneTables.run(["--fixture", out_dir()])

    for {name, size} <- [{"router.table", 20}, {"member.table", 54}, {"keys.2.table", 100}] do
      line = "#{name}  #{size} bytes  sha256 #{@sha256[name]}"
      assert_received {:mix_shell, :info, [^line]}
    end
  end

  test "another seed gives other keys and the same router and member tables" do
    [one, two] = for _ <- 1..2, do: out_dir()
    :ok = ZoneTables.run(["--fixture", one])
    :ok = ZoneTables.run(["--fixture", "--seed", "2", two])
    {a, b} = {read(one), read(two)}

    assert Map.take(a, ~w(router.table member.table)) ==
             Map.take(b, ~w(router.table member.table))

    for slot <- 0..3, do: refute(a["keys.#{slot}.table"] == b["keys.#{slot}.table"])
  end

  test "control: a run without a directory, or with an option it does not know, is refused" do
    for args <- [[], ["--fixture"], ["--fixture", "a", "b"], ["zone"], ["--nope", "z", "dir"]] do
      assert_raise Mix.Error, ~r/mix uro.zone_tables/, fn -> ZoneTables.run(args) end
    end

    assert_raise Mix.Error, ~r/OBJECT:FIRST:LAST/, fn ->
      ZoneTables.run(["z", out_dir(), "--range", "ball-7:1"])
    end
  end

  defp decode_keys!(bytes) do
    {:ok, keys} = Tables.decode_keys_table(bytes)
    keys
  end
end

defmodule Mix.Tasks.Uro.ZoneTablesTest do
  @moduledoc """
  `mix uro.zone_tables ZONE_ID DIR` on a zone that is seated in this node.

  The task reads the `Uro.Zones.Slots` and `Uro.Zones.PairKeys` of the application, so
  each test seats its users in a zone id of its own and takes them out again. The files
  must be what the encoders give for `Uro.Zones.Tables.inputs/2`, and each keys file must
  be what `Uro.Zones.PairKeys.keys_for/3` gives that slot and not what it gives another.
  """
  use Uro.RepoCase, async: false

  alias Mix.Tasks.Uro.ZoneTables
  alias Uro.Tuples
  alias Uro.Zones.PairKeys
  alias Uro.Zones.Slots
  alias Uro.Zones.Tables

  @names ~w(keys.0.table keys.1.table keys.2.table keys.3.table member.table router.table)

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    zone = System.unique_integer([:positive]) + 1_000_000
    dir = Path.join(System.tmp_dir!(), "uro-zone-tables-live-#{zone}")

    on_exit(fn ->
      Mix.shell(shell)
      for user <- Slots.table(zone), user != nil, do: Slots.leave(zone, user)
      PairKeys.refresh(zone)
      for name <- @names, do: File.rm(Path.join(dir, name))
      File.rmdir(dir)
    end)

    %{zone: zone, dir: dir}
  end

  defp seat(users, zone) do
    for user <- users, do: {:ok, _} = Slots.join(zone, user)
    :ok = PairKeys.refresh(zone)
  end

  test "the files are the tables of the zone and each member's own keys", ctx do
    %{zone: zone, dir: dir} = ctx
    seat(~w(a b c), zone)
    {:ok, _} = Tuples.put("a", "SEND", "#{zone}")
    {:ok, _} = Tuples.put("c", "SEES", "avatar:a")
    {:ok, _} = Tuples.replace("CONTROLS", "ball-7", "b")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "keys.3.table"), "left by an earlier run")

    assert ZoneTables.run(["#{zone}", dir, "--range", "ball-7:100:199"]) == :ok

    {:ok, inputs} = Tables.inputs(zone, ranges: [{"ball-7", 100, 199}])
    assert Enum.sort(File.ls!(dir)) == @names -- ["keys.3.table"]

    assert File.read!(Path.join(dir, "router.table")) ==
             Tables.router_table(inputs.slots, inputs.sees)

    assert File.read!(Path.join(dir, "member.table")) ==
             Tables.member_table(inputs.slots, inputs.controls)

    assert {:ok, [%{first_gid: 100, last_gid: 199, slot: 1, epoch: 1} | _]} =
             Tables.decode_member_table(File.read!(Path.join(dir, "member.table")))

    for {owner, slot} <- Enum.with_index(~w(a b c)), reader <- ~w(a b c) do
      {:ok, keys} = Tables.decode_keys_table(File.read!(Path.join(dir, "keys.#{slot}.table")))
      assert map_size(keys) == 2
      assert keys == PairKeys.keys_for(zone, reader) == (owner == reader)
    end
  end

  test "a zone nobody is in gives an empty router and member table and no keys file", ctx do
    assert ZoneTables.run(["#{ctx.zone}", ctx.dir]) == :ok

    assert Enum.sort(File.ls!(ctx.dir)) == ~w(member.table router.table)
    assert File.read!(Path.join(ctx.dir, "router.table")) == <<0::160>>
    assert File.read!(Path.join(ctx.dir, "member.table")) == <<0, 0>>
  end

  test "control: ranges that share an entity id are refused and nothing is written", ctx do
    seat(~w(a), ctx.zone)

    assert_raise Mix.Error, ~r/overlap/, fn ->
      ZoneTables.run(["#{ctx.zone}", ctx.dir, "--range", "x:1:5", "--range", "y:5:9"])
    end

    refute File.exists?(Path.join(ctx.dir, "router.table"))
  end

  test "control: keys that are not those of the seats are an error, not files", ctx do
    seat(~w(a b), ctx.zone)
    {:ok, _} = Slots.join(ctx.zone, "c")

    assert Tables.zone_files(ctx.zone) == {:error, :changed}

    :ok = PairKeys.refresh(ctx.zone)
    assert {:ok, files} = Tables.zone_files(ctx.zone)

    assert Enum.map(files, &elem(&1, 0)) ==
             ~w(router.table member.table) ++ ~w(keys.0.table keys.1.table keys.2.table)
  end
end

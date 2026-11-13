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

  ## The member table

  `member_table/2` is the same for every member of the zone. It says which slot controls
  each range of entity ids, and at which epoch: a count of rows (u16), then for each row
  `first_gid` (u32), `last_gid` (u32, the range includes both), `slot` (u8, the slot of the
  controller, or 255 when the controller is not seated) and `epoch` (u32). All integers
  are little-endian and the rows are in the order of `first_gid`. It is `2 + 13 * rows`
  bytes.

  The rows are the body of each seated user, controlled by the user's own slot at the
  epoch of the user's avatar object, and one row for each entry of `controls`. An entry
  is a map with `:first_gid`, `:last_gid`, `:controller` (a user id, or `nil` for nobody)
  and `:epoch`. No two rows may share an entity id. Inputs that break this, or a value
  that does not fit its field, are an error of the caller and raise `ArgumentError`;
  `check/2` gives the same answer as `:ok` or `{:error, reason}`.

  ## User numbers and avatar objects

  The body of a user is the 21 entity ids from `2_000_000 + 21 * number`, where `number`
  is the user number (`body_range/1`). The highest entity id is `2^32 - 1`, so the highest
  user number is 204_427_013 (`max_user_number/0`).

  The id of a user is a UUID (`Uro.Accounts.User` has a `:binary_id` key), which does not
  fit. `user_number/1` derives the number from the id alone: the first four bytes of the
  SHA-256 of the id string, as a big-endian integer, modulo 204_427_014. No column and no
  process holds it. This was chosen over a number the zone gives out at join because:

    * it is the same in every zone, on every node and after every restart, so an entity
      range always belongs to the same user, and a client can work it out from a user id;
    * the epoch of a body is the epoch of the user's avatar object, which never goes down
      (`Uro.Tuples`). A number given out at join would be given to another user after a
      restart, and that user's avatar object could be at an epoch the range has had
      before. With a number that is fixed to the user, a range and an epoch name one
      controller for the life of the database.

  Two users can have the same number. For two given users the chance is 1 in
  204_427_014, and a zone seats four. The encoder does not let it pass: two seated users
  with one number have bodies that overlap, which is refused as any overlap is.

  The avatar object of a user is the string `"avatar:"` followed by the user id
  (`avatar_object/1`). It is the object of the `SEES` tuples and the object whose epoch
  the body row carries. The existing tuples name a user and a zone by the bare id, so the
  prefix keeps the body of a user apart from the user as a subject.

  ## The keys table

  `keys_table/1` is for one member: the keys of that member's pairs, as
  `Uro.Zones.PairKeys.keys_for/3` returns them (a map from the slot of each other member
  to the key the two share). It is a count (u8), then for each other slot the slot (u8)
  and the 32 bytes of the key, in slot order: `1 + 33 * keys` bytes. It is the only
  encoder that is given a key. `router_table/2` and `member_table/2` have no key among
  their arguments, so no caller can make them write one.

  ## Gathering the inputs

  `inputs/2` is the one function here that reads state: the zone's table from
  `Uro.Zones.Slots`, and the tuples and epochs from `Uro.Tuples`. In the tuples a user is
  named by its id and a zone by its id, each as a string, as `Uro.VSekai` names them:

    * `:send` of a seat is the tuple (user, `SEND`, zone);
    * a `{viewer, sender}` pair of `sees` is the tuple (viewer, `SEES`, avatar object of
      the sender), looked up for each ordered pair of seated users;
    * `:epoch` of a seat is the epoch of the user's avatar object;
    * `:number` of a seat is `user_number/1` of the user id.

  The repository has no list of the entities of a zone, so the caller gives the further
  ranges in the option `:ranges`, each as `{object, first_gid, last_gid}`. The controller
  of a range is the subject of the tuple (subject, `CONTROLS`, object), and its epoch is
  the epoch of the object. `Uro.Tuples.replace/3` leaves one such subject. If puts have
  left several, the first in subject order who is seated is taken, and without one who is
  seated the first in subject order. An object nobody controls has the controller `nil`.

  The result is `{:ok, inputs}` only when `check/2` accepts it, so the encoders do not
  raise on it.

  ## Files

  `files/2` names the tables as `mix uro.zone_tables` writes them: `router.table`,
  `member.table`, and `keys.<slot>.table` for each seated slot. `zone_files/2` gathers a
  zone and gives its files. It reads the slot table once; if the keys that
  `Uro.Zones.PairKeys` holds are not those of that table (a member joined or left in
  between, or the keys were not refreshed) it returns `{:error, :changed}`, and the caller
  may ask again.

  `fixture/1` is a fixed zone that needs no database and no process: user numbers 7, 9,
  12 and 30 in slots 0 to 3, everyone may send, everyone sees everyone, every epoch 0, no
  further range. The key of slots `a < b` is the SHA-256 of the string
  `uro.zone_tables fixture seed=<seed> pair=<a>,<b>`, so a seed always gives the same
  files, on any version of Erlang. These keys are public and must protect nothing.
  """

  import Bitwise

  alias Uro.Tuples
  alias Uro.Zones.PairKeys
  alias Uro.Zones.Slots

  @slots 4
  @body_base 2_000_000
  @body_ids 21
  @max_u32 (1 <<< 32) - 1
  @max_number div(@max_u32 - @body_base - (@body_ids - 1), @body_ids)
  @not_seated 255

  @type seat :: %{
          user: String.t(),
          number: non_neg_integer(),
          send: boolean(),
          epoch: non_neg_integer()
        }
  @type slots :: [seat() | nil]
  @type sees :: MapSet.t({String.t(), String.t()})
  @type router :: %{send: [boolean()], sees: MapSet.t({0..3, 0..3})}
  @type control :: %{
          first_gid: non_neg_integer(),
          last_gid: non_neg_integer(),
          controller: String.t() | nil,
          epoch: non_neg_integer()
        }
  @type row :: %{
          first_gid: non_neg_integer(),
          last_gid: non_neg_integer(),
          slot: 0..3 | 255,
          epoch: non_neg_integer()
        }
  @type range :: {String.t(), non_neg_integer(), non_neg_integer()}
  @type inputs :: %{slots: slots(), sees: sees(), controls: [control()]}
  @type reason ::
          {:overlap, row(), row()} | {:out_of_range, row()} | {:user_number, term()} | :too_many
  @type slot_keys :: %{Slots.slot() => PairKeys.key()}
  @type file :: {String.t(), binary()}

  @doc "The user number of a user id. See the moduledoc for how and why."
  @spec user_number(String.t()) :: non_neg_integer()
  def user_number(user_id) when is_binary(user_id) do
    <<head::32, _rest::binary>> = :crypto.hash(:sha256, user_id)
    rem(head, @max_number + 1)
  end

  @spec max_user_number() :: non_neg_integer()
  def max_user_number, do: @max_number

  @doc "The name of the avatar object of a user in the stored tuples."
  @spec avatar_object(String.t()) :: String.t()
  def avatar_object(user_id) when is_binary(user_id), do: "avatar:" <> user_id

  @doc "The first and the last entity id of the body of a user number."
  @spec body_range(non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def body_range(number) when is_integer(number) and number >= 0 do
    first = @body_base + number * @body_ids
    {first, first + @body_ids - 1}
  end

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

  @doc """
  Says whether `member_table/2` accepts the inputs: `:ok`, or the first thing that is
  wrong. `{:user_number, n}` is a user number outside `0..max_user_number()`,
  `{:out_of_range, row}` a row with a value that does not fit or a range that ends before
  it starts, `{:overlap, a, b}` two rows that share an entity id, and `:too_many` more
  than 65_535 rows.
  """
  @spec check(slots(), [control()]) :: :ok | {:error, reason()}
  def check(slots, controls) do
    with {:ok, _rows} <- rows(slots, controls), do: :ok
  end

  @spec member_table(slots(), [control()]) :: binary()
  def member_table(slots, controls) do
    case rows(slots, controls) do
      {:ok, rows} ->
        body =
          for r <- rows, into: <<>> do
            <<r.first_gid::32-little, r.last_gid::32-little, r.slot, r.epoch::32-little>>
          end

        <<length(rows)::16-little, body::binary>>

      {:error, reason} ->
        raise ArgumentError, "the member table was refused: #{inspect(reason)}"
    end
  end

  @doc """
  Reads a member table into its rows, in the order they are in. A binary whose size is
  not what its count says, whose rows are not in order or share an entity id, or that has
  a slot other than 0 to 3 or 255, is `{:error, :malformed}`.
  """
  @spec decode_member_table(binary()) :: {:ok, [row()]} | {:error, :malformed}
  def decode_member_table(<<count::16-little, body::binary>>)
      when byte_size(body) == count * 13 do
    rows =
      for <<first::32-little, last::32-little, slot, epoch::32-little <- body>> do
        %{first_gid: first, last_gid: last, slot: slot, epoch: epoch}
      end

    well_formed? =
      Enum.all?(rows, fn r ->
        (r.slot < @slots or r.slot == @not_seated) and r.first_gid <= r.last_gid
      end)

    if well_formed? and ordered(rows) == :ok, do: {:ok, rows}, else: {:error, :malformed}
  end

  def decode_member_table(binary) when is_binary(binary), do: {:error, :malformed}

  defp rows(slots, controls) when length(slots) == @slots do
    seated = for {seat, slot} <- Enum.with_index(slots), seat != nil, do: {seat, slot}
    by_user = Map.new(seated, fn {seat, slot} -> {seat.user, slot} end)

    further =
      for c <- controls do
        slot = Map.get(by_user, c.controller, @not_seated)
        %{first_gid: c.first_gid, last_gid: c.last_gid, slot: slot, epoch: c.epoch}
      end

    with :ok <- numbers(seated) do
      bodies =
        for {seat, slot} <- seated do
          {first, last} = body_range(seat.number)
          %{first_gid: first, last_gid: last, slot: slot, epoch: seat.epoch}
        end

      rows = Enum.sort_by(bodies ++ further, &{&1.first_gid, &1.last_gid, &1.slot})

      with :ok <- fits(rows), :ok <- ordered(rows) do
        if length(rows) > 65_535, do: {:error, :too_many}, else: {:ok, rows}
      end
    end
  end

  defp numbers(seated) do
    case Enum.find(seated, fn {seat, _} -> not u?(seat.number, @max_number) end) do
      nil -> :ok
      {seat, _slot} -> {:error, {:user_number, seat.number}}
    end
  end

  defp fits(rows) do
    bad =
      Enum.find(rows, fn r ->
        not (u?(r.first_gid, @max_u32) and u?(r.last_gid, @max_u32) and u?(r.epoch, @max_u32) and
               r.first_gid <= r.last_gid)
      end)

    if bad, do: {:error, {:out_of_range, bad}}, else: :ok
  end

  defp ordered(rows) do
    case Enum.find(Enum.zip(rows, Enum.drop(rows, 1)), fn {a, b} -> b.first_gid <= a.last_gid end) do
      nil -> :ok
      {a, b} -> {:error, {:overlap, a, b}}
    end
  end

  defp u?(value, max), do: is_integer(value) and value >= 0 and value <= max

  @spec keys_table(%{Slots.slot() => PairKeys.key()}) :: binary()
  def keys_table(keys) when is_map(keys) do
    body =
      for {slot, <<key::binary-size(32)>>} when slot in 0..3 <- Enum.sort(keys), into: <<>> do
        <<slot, key::binary>>
      end

    if byte_size(body) != 33 * map_size(keys) do
      raise ArgumentError, "a keys table takes slots 0 to 3 and keys of 32 bytes"
    end

    <<map_size(keys), body::binary>>
  end

  @doc """
  Reads a keys table into a map from slot to key. A binary whose size is not what its
  count says, whose slots are not in order, or that has a slot above 3, is
  `{:error, :malformed}`.
  """
  @spec decode_keys_table(binary()) ::
          {:ok, %{Slots.slot() => PairKeys.key()}} | {:error, :malformed}
  def decode_keys_table(<<count, body::binary>>) when byte_size(body) == count * 33 do
    entries = for <<slot, key::binary-size(32) <- body>>, do: {slot, key}
    slots = Enum.map(entries, &elem(&1, 0))

    if Enum.all?(slots, &(&1 < @slots)) and slots == Enum.uniq(Enum.sort(slots)),
      do: {:ok, Map.new(entries)},
      else: {:error, :malformed}
  end

  def decode_keys_table(binary) when is_binary(binary), do: {:error, :malformed}

  @doc """
  Gathers the inputs of the encoders for `zone_id` as it is now. `:slots` is the
  `Uro.Zones.Slots` server (that module by default) and `:ranges` the further entity
  ranges (none by default). See "Gathering the inputs" in the moduledoc.
  """
  @spec inputs(Slots.zone_id(), keyword()) :: {:ok, inputs()} | {:error, reason()}
  def inputs(zone_id, opts \\ []) do
    table = Slots.table(zone_id, Keyword.get(opts, :slots, Slots))
    gather(table, to_string(zone_id), Keyword.get(opts, :ranges, []))
  end

  @doc """
  The files of the tables, in the order router, member, then keys by slot. `keys` maps
  each seated slot to the keys of that slot's pairs.
  """
  @spec files(inputs(), %{Slots.slot() => slot_keys()}) :: [file()]
  def files(%{slots: slots, sees: sees, controls: controls}, keys) do
    seated = for {seat, slot} <- Enum.with_index(slots), seat != nil, do: slot

    [{"router.table", router_table(slots, sees)}, {"member.table", member_table(slots, controls)}] ++
      for(slot <- seated, do: {"keys.#{slot}.table", keys_table(Map.fetch!(keys, slot))})
  end

  @doc """
  Gathers `zone_id` and gives its files. The options are those of `inputs/2`, and `:keys`
  for the `Uro.Zones.PairKeys` server (that module by default).
  """
  @spec zone_files(Slots.zone_id(), keyword()) ::
          {:ok, [file()]} | {:error, reason() | :changed}
  def zone_files(zone_id, opts \\ []) do
    table = Slots.table(zone_id, Keyword.get(opts, :slots, Slots))
    seated = for {user, slot} <- Enum.with_index(table), user != nil, do: {slot, user}
    server = Keyword.get(opts, :keys, PairKeys)

    with {:ok, inputs} <- gather(table, to_string(zone_id), Keyword.get(opts, :ranges, [])) do
      keys =
        Map.new(seated, fn {slot, user} -> {slot, PairKeys.keys_for(zone_id, user, server)} end)

      slots = Enum.map(seated, &elem(&1, 0))

      if Enum.all?(keys, fn {slot, held} -> Map.keys(held) == slots -- [slot] end),
        do: {:ok, files(inputs, keys)},
        else: {:error, :changed}
    end
  end

  @doc "The fixed zone of `mix uro.zone_tables --fixture`: its inputs and its keys by slot."
  @spec fixture(integer()) :: {inputs(), %{Slots.slot() => slot_keys()}}
  def fixture(seed \\ 1) when is_integer(seed) do
    slots =
      for number <- [7, 9, 12, 30] do
        %{user: "fixture-user-#{number}", number: number, send: true, epoch: 0}
      end

    users = Enum.map(slots, & &1.user)

    sees =
      for viewer <- users,
          sender <- users,
          viewer != sender,
          into: MapSet.new(),
          do: {viewer, sender}

    keys =
      for slot <- 0..3, into: %{} do
        {slot,
         for(other <- 0..3, other != slot, into: %{}, do: {other, fixture_key(seed, slot, other)})}
      end

    {%{slots: slots, sees: sees, controls: []}, keys}
  end

  defp fixture_key(seed, a, b) when is_integer(a) and is_integer(b) do
    :crypto.hash(:sha256, "uro.zone_tables fixture seed=#{seed} pair=#{min(a, b)},#{max(a, b)}")
  end

  defp gather(table, zone, ranges) do
    users = for user <- table, user != nil, do: to_string(user)

    slots =
      for user <- table do
        if user != nil do
          user = to_string(user)

          %{
            user: user,
            number: user_number(user),
            send: Tuples.has?(user, "SEND", zone),
            epoch: Tuples.epoch(avatar_object(user))
          }
        end
      end

    sees =
      for viewer <- users,
          sender <- users,
          viewer != sender,
          Tuples.has?(viewer, "SEES", avatar_object(sender)),
          into: MapSet.new(),
          do: {viewer, sender}

    controls =
      for {object, first, last} <- ranges do
        holders = for t <- Tuples.list_for_object(object), t.verb == "CONTROLS", do: t.subject
        controller = Enum.find(holders, List.first(holders), &(&1 in users))
        %{first_gid: first, last_gid: last, controller: controller, epoch: Tuples.epoch(object)}
      end

    with :ok <- check(slots, controls) do
      {:ok, %{slots: slots, sees: sees, controls: controls}}
    end
  end

  defp sees?(nil, _sender, _sees), do: false
  defp sees?(_viewer, nil, _sees), do: false
  defp sees?(%{user: same}, %{user: same}, _sees), do: false
  defp sees?(viewer, sender, sees), do: MapSet.member?(sees, {viewer.user, sender.user})

  defp flag(true), do: 1
  defp flag(false), do: 0
end

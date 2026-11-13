# Zone tables

A zone has up to four members, one in each slot (`Uro.Zones.Slots`). The relay of the
zone and its members each need a small table that says who may do what. Uro makes these
tables from the slots and the stored relationship tuples (`Uro.Tuples`).

The encoders are in `Uro.Zones.Tables`. They are pure functions from data to bytes, so
a test in another repository can read exactly the bytes that a client would be sent.

| File | Who gets it | What it says |
|------|-------------|--------------|
| `router.table` | the relay, and only this file | which slots may send, and which slot sees which |
| `member.table` | every member, the same bytes | which slot controls each range of entity ids, and at which epoch |
| `keys.<slot>.table` | the member in that slot, and nobody else | the keys that member shares with each other member |

The relay must never hold a key. `router_table/2` and `member_table/2` have no key among
their arguments, so no caller can make them write one. `keys_table/1` is the only encoder
that is given keys, and it is given the keys of one member.

All integers are little-endian. A table has no header, no version and no padding.

## `router.table`

Always 20 bytes.

| Bytes | Field | Value |
|-------|-------|-------|
| 0 | `send[0]` | 1 when slot 0 is seated and its user holds the tuple (user, `SEND`, zone), else 0 |
| 1 | `send[1]` | the same for slot 1 |
| 2 | `send[2]` | the same for slot 2 |
| 3 | `send[3]` | the same for slot 3 |
| 4..7 | `sees[0][0..3]` | row of the viewer in slot 0 |
| 8..11 | `sees[1][0..3]` | row of the viewer in slot 1 |
| 12..15 | `sees[2][0..3]` | row of the viewer in slot 2 |
| 16..19 | `sees[3][0..3]` | row of the viewer in slot 3 |

The matrix is in row-major order: the cell for viewer slot `v` and sender slot `s` is
byte `4 + 4 * v + s`. A cell is 1 when the viewer is seated, the sender is seated, they
are different slots, and the viewer's user holds the tuple (viewer, `SEES`, avatar object
of the sender's user). Every other cell is 0. The diagonal (bytes 4, 9, 14 and 19) is
always 0.

A byte is 0 or 1. `decode_router_table/1` refuses any other byte, a set diagonal and a
size other than 20.

## `member.table`

`2 + 13 * rows` bytes.

| Bytes | Field | Type | Value |
|-------|-------|------|-------|
| 0..1 | `count` | u16 | the number of rows |

Then, for each row `i` from 0, at offset `2 + 13 * i`:

| Bytes of the row | Field | Type | Value |
|------------------|-------|------|-------|
| 0..3 | `first_gid` | u32 | the first entity id of the range |
| 4..7 | `last_gid` | u32 | the last entity id of the range; the range includes it |
| 8 | `slot` | u8 | the slot that controls the range, 0 to 3, or 255 when the controller is not seated |
| 9..12 | `epoch` | u32 | the epoch of the object the range stands for |

The rows are in the order of `first_gid`, and no two rows share an entity id.
`decode_member_table/1` refuses a table that breaks either rule, a size that is not what
`count` says, a range that ends before it starts, and a slot of 4 to 254.

The rows are:

- the body of each seated user: `first_gid = 2_000_000 + 21 * user number`,
  `last_gid = first_gid + 20`, controlled by the user's own slot, at the epoch of the
  user's avatar object;
- one row for each further range that the caller names (see `--range` below): the
  controller is the subject of the tuple (subject, `CONTROLS`, object), and the epoch is
  the epoch of the object.

An epoch goes up by one each time `Uro.Tuples.replace/3` hands the object to a new
subject, and it never goes down or repeats. A member that has a row with a lower epoch
than one it has seen for the same range has an old table.

### User numbers and avatar objects

The id of a user is a UUID, which does not fit in an entity id. The user number is
derived from the id alone (`user_number/1`):

    number = (first 4 bytes of SHA-256(user id string), big-endian) mod 204_427_014

The highest number, 204_427_013, puts the last entity id of a body at 4_294_967_293,
below 2^32. No column and no process holds the number. It is the same in every zone and
after every restart, so a range of body entity ids always belongs to the same user, and
a range with an epoch names one controller for the life of the database. A number that
the zone gave out at join would be given to another user after a restart, whose avatar
object could be at an epoch that the range had before.

Two users can have the same number: for two given users the chance is 1 in 204_427_014.
Their bodies would be the same range, so a zone that seats both gets no member table:
`Uro.Zones.Tables.inputs/2` returns `{:error, {:overlap, row, row}}`.

The avatar object of a user is the string `avatar:` followed by the user id
(`avatar_object/1`). The user itself is named by the bare id, and a zone by its bare id,
as `Uro.VSekai` names them in its tuples.

## `keys.<slot>.table`

`1 + 33 * keys` bytes. One file for each seated slot; `<slot>` is the slot of the member
the file is for.

| Bytes | Field | Type | Value |
|-------|-------|------|-------|
| 0 | `count` | u8 | the number of other seated members, 0 to 3 |

Then, for each other seated slot in rising order, at offset `1 + 33 * i`:

| Bytes of the entry | Field | Type | Value |
|--------------------|-------|------|-------|
| 0 | `slot` | u8 | the slot of the other member |
| 1..32 | `key` | 32 bytes | the key the two members share (`Uro.Zones.PairKeys`) |

A member who is alone gets the one byte `00`. The file has the keys of the pairs its
member is in and of no other pair. To check that a file is the right one for a slot,
decode it and compare it with `Uro.Zones.PairKeys.keys_for/3` for that slot's user.

## The task

    mix uro.zone_tables ZONE_ID DIR [--range OBJECT:FIRST:LAST ...]
    mix uro.zone_tables --fixture DIR [--seed N]

The task writes the files into `DIR`, which it makes if it is not there, and prints one
line for each file with its size and its SHA-256. It removes a `keys.<slot>.table` in
`DIR` for a slot that is not seated now, and no other file.

With a zone id it starts the application and reads the zone as it is now. A zone id of
digits is taken as an integer. `--range` may be given several times: `OBJECT` is the
object of the `CONTROLS` tuples and `FIRST` and `LAST` are the range of entity ids it
stands for. The repository has no list of the entities of a zone, so the caller names
them. If two ranges share an entity id, or the members change while the task reads them,
the task stops with the reason and writes nothing.

The slots and the keys are in the memory of the node that serves the zone. A `mix`
command starts a node of its own, where nobody is seated, and writes an empty router
table, an empty member table and no keys file. For a zone that is in use, call
`Uro.Zones.Tables.zone_files/2` in the node that serves it.

## The fixture

`mix uro.zone_tables --fixture DIR` reads no database and starts nothing. It writes a
fixed zone, so that a gate in another repository can call it and compare bytes:

- slots 0, 1, 2 and 3 hold the user numbers 7, 9, 12 and 30;
- every member may send, and every member sees every other member;
- every epoch is 0, and there is no further range;
- the key of the pair of slots `a < b` is the SHA-256 of the ASCII string
  `uro.zone_tables fixture seed=<seed> pair=<a>,<b>`. The seed is 1 unless `--seed` says
  otherwise.

These keys are public. They are for tests and must protect nothing.

`router.table` is `01 01 01 01`, then `00 01 01 01`, `01 00 01 01`, `01 01 00 01`,
`01 01 01 00`. `member.table` has the four bodies: entity ids 2_000_147 to 2_000_167 for
slot 0, 2_000_189 to 2_000_209 for slot 1, 2_000_252 to 2_000_272 for slot 2 and
2_000_630 to 2_000_650 for slot 3.

With the default seed the files are:

| File | Bytes | SHA-256 |
|------|-------|---------|
| `router.table` | 20 | `2b16c312ba4e29bd93471fc61c8da7263eed5a3c8306eddcaef9d2fc3f3426bf` |
| `member.table` | 54 | `51a2f8087f92fb4099541df54919abacf6340b43db3e9fcc00b258580cf1e9f5` |
| `keys.0.table` | 100 | `5c101b0083c9dadb3c9a5ceb9e8bb0e15f1a1de7a1eda89588854a2e6a54c3aa` |
| `keys.1.table` | 100 | `71bae1f085920db37678609f3c4a87b075b2bff47556161fe00770453a1dec39` |
| `keys.2.table` | 100 | `32f6c999857fd1cd85d0d3b040db560cb8da6246fb73d861dd3bf038c71e4562` |
| `keys.3.table` | 100 | `9157f305739a35b95a1175ef716b86805e13f9ad7c39285f456f288ca6f74dd4` |

`router.table` and `member.table` do not change with the seed. The test
`Mix.Tasks.Uro.ZoneTablesFixtureTest` runs the task twice, compares the bytes, and checks
these values against the files and against this page.

# t3kv

A small embedded key-value store written in Zig, built for agent memory: many
small records, grouped by an agent or conversation prefix, read by key or as
"the latest N".

It is inspired by [kiban](https://github.com/aetosdios27/kiban) but uses a
different, lighter design:

- **Append-only segment files** hold every record, each with a CRC-32C.
- **An ordered in-memory index** maps each key to its record's location on disk
  (coming in the next change), so a read is one lookup plus one disk read.
- **Compaction** rewrites one sealed segment at a time.
- **Snapshots** are just sequence numbers, so taking one copies nothing.

The trade-off: every key must fit in memory (about 40 bytes plus the key per
live record).

## Status

Early work in progress. This first change contains the on-disk layer only:

- Record encoding (`src/record.zig`)
- Segment naming and scanning with torn-tail detection (`src/segment.zig`)
- The log: directory lock, append, sync, rollover, read-back and crash
  recovery (`src/Log.zig`)

## Recovery rules

- A crash in the middle of a write leaves a torn record at the end of the
  active segment. Opening the log truncates it.
- If a damaged record is followed by valid records, data in the middle was
  lost. Opening fails with `error.Corrupt` instead of silently cutting it off.
- Sealed segments were synced before the next one was created, so any damage
  in them is `error.Corrupt`.
- Only one process may open a directory; a second open gets `error.Locked`.

## Build

Requires Zig 0.17.0. No other dependencies.

```sh
zig build test
```

Licensed under MIT.

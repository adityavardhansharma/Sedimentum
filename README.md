# Sedimentum

A small embedded key-value store written in Zig, built for agent memory: many
small records, grouped by an agent or conversation prefix, read by key or as
"the latest N".

It is inspired by [kiban](https://github.com/aetosdios27/kiban) but is not a
port. kiban is an LSM tree (memtable, WAL, sorted SSTables). Sedimentum is a
log-structured hash/tree store:

- **Append-only segment files** hold every record, each with a CRC-32C and a
  sequence number. Appends go through a user-space write buffer.
- **An in-memory index** maps each key to its record's location: a hash table
  for point reads and a B+tree with linked leaves for ordered and reverse scans.
  A read is one hash lookup plus one memory-mapped read.
- **Group commit**: concurrent durable writers share one `fsync`. A leader
  syncs without holding any lock while others queue behind it.
- **Compaction** copies the live records of one sealed segment forward with
  their original sequence numbers, so recovery always resolves a key by the
  highest sequence number it has seen.
- **Snapshots** are sequence numbers plus per-key version chains. Taking one
  copies nothing.

The trade-off: every key must fit in memory. With 40-byte keys that is about
200 bytes per live record (1M records use about 210 MB of RAM).

## Features

- `put`, `get`, `delete`, durable or buffered
- Atomic batches (`write`) that recover all-or-nothing, even if torn mid-write
- Compare-and-swap: `putIf(key, value, .absent | .{ .seq = n })`, `seqOf`
- Expiring values: `putTtl`
- `deletePrefix` for dropping a whole agent or conversation
- Ordered iterators, prefix iterators, reverse iteration, `latest(prefix, n)`
- Point-in-time snapshots: `snapshot`, `getAt`, iterators at a snapshot
- `Shared`: a thread-safe handle with readers in parallel and group commit
- A C ABI (`libsedimentum`, `include/sedimentum.h`) for other languages
- A `sedimentum` CLI: `stats`, `check`, `get`, `put`, `delete`, `scan`, `compact`

## Recovery rules

- A crash in the middle of a write leaves a torn record at the end of the
  active segment. Opening truncates it. A torn batch is dropped whole.
- If a damaged record is followed by valid records, data in the middle was
  lost. Opening fails with `error.Corrupt` instead of silently cutting it off.
- Sealed segments were synced before the next one was created, so any damage
  in them is `error.Corrupt`.
- Only one process may open a directory; a second open gets `error.Locked`.
- A durable write returns only after its bytes are synced.

## Build

Requires Zig 0.17.0. No other dependencies.

```sh
zig build test                  # run the tests
zig build                       # library, CLI and C shared library in zig-out/
zig build -Doptimize=ReleaseFast
```

## Benchmarks

`src/bench.zig` and `bench/kiban-bench` run the same agent-memory workload
(64 agents, 200-byte values, same seeds and key layout) against Sedimentum
and kiban v0.2.0:

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/sedimentum-bench /tmp/sdm 1000000
cd bench/kiban-bench && cargo build --release
target/release/kiban-bench /tmp/kiban 1000000
```

Each prints one JSON line per phase.

Licensed under MIT.

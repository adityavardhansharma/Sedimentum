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

By default every key lives in memory: with 40-byte keys that is about 200
bytes per live record (1M records use about 210 MB of RAM).

## More data than RAM

Set `memory_budget` (bytes) to cap the in-memory index. When it grows past the
budget, the entries for sealed segments are merged into **the cold index**
(`cold.idx`), a sorted file with a bloom filter and a one-key-per-block summary,
and dropped from memory:

- Recent data stays in memory and is as fast as before. A read of older data
  checks the bloom filter (no disk access when the key is absent), then reads
  one 4 KB block through a memory map.
- Writing a key that only the cold index knows first copies its entry into
  memory, so writes, batches, CAS and compaction all work as before.
- Opening skips the segments the cold index covers, so reopening a large
  database takes a fraction of the time.
- Merges pause while a snapshot is open and run when the log starts a new
  segment.

`cold.idx` is part of the database: keep it with the segment files.

## Stream stores: v2 and v3

`sdm.streams.V2` and `sdm.streams.V3` are two more engines built around
streams instead of one global index. A stream is every key up to its second
`/` (`chat/42/`, `agent/7/`). Each stream keeps its newest writes in a small
tail and everything older in sorted, immutable chunks. Only chunk fences and
bloom filters stay in RAM, so memory stays flat as data grows.

- **v2**: a write-ahead log (the v1 segment log) plus 64 KB tails in RAM.
  Tails are sealed into chunks of plain 4 KB blocks and merged eight runs at
  a time; runs that don't overlap (keys that grow or shrink with time) are
  linked instead of rewritten. One lock, group commit.
- **v3 (Lean)**: no write-ahead log. Each stream's 16 KB tail is a page in the
  data file that is rewritten in place and recovered by sequence number and
  checksum. Keys are front-coded, blocks are LZ4 compressed, and streams
  are spread over one shard per core, each with its own lock and fsync.

A directory remembers which engine made it (`FORMAT`), so opening it with
the other one fails with `error.WrongEngine` instead of damaging it;
`streams.detect` tells them apart.

### What each engine can do

| | v1 | v2 | v3 | kiban |
|---|---|---|---|---|
| get, put, delete, durable or buffered | yes | yes | yes | yes |
| Ordered and reverse scans, `latest(prefix, n)` | yes | yes | yes | forward only |
| Point-in-time snapshots | yes | yes | yes (across shards) | yes |
| Atomic batches (`write`) | yes | yes (WAL batch) | yes (batch journal) | yes |
| Expiring values (`putTtl`) | yes | yes | yes | no |
| Compare-and-swap (`putIf`, `seqOf`) | yes | yes | yes | no |
| `deletePrefix` | yes | yes, whole streams without reading | same as v2 | no |
| Thread-safe handle with group commit | `Shared` | built in | built in, one lock per shard | `SharedKiban` |
| Integrity check (`verify`, CLI `check`) | CLI | yes | yes | yes |
| Online `backup` to a new directory | no | yes | yes | yes |
| `checkpoint` / flush | sync | yes | yes | yes |
| Stats | yes | yes | yes | yes |
| Atomic counters (`incr`) | no | yes | yes | no |
| Retention: keep the newest N of a prefix (`trim`) | no | yes | yes | no |
| Per-stream listing with sizes (`listStreams`) | no | yes | yes | no |
| Multi-get (`getMany`), `count(range)`, `contains` | count, contains | yes | yes | no |
| RAM stays flat as data grows | with the memory cap | yes | yes | yes |
| C ABI and CLI | yes | yes | yes | Rust only |

v3 makes a batch that touches several streams atomic with a small journal
(`BATCHES`): the batch is written there first, and every shard syncs the
journal before it writes a page or a manifest, so no part of a batch can be
durable before all of it is. On open, any batch operation a stream does not
already hold (by sequence number) is put back, then the journal is emptied.

`compact` copies live data into a fresh file and deletes the old one;
expired values are dropped there and in merges.

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
- A `sedimentum` CLI: `stats`, `check`, `get`, `put`, `delete`, `scan`, `compact`,
  and for stream stores `streams`, `incr`, `trim`, `backup`, `checkpoint`.
  `--engine v2|v3` picks the engine for a new directory; an existing one is
  detected. The C ABI opens any engine with `sdm_open_engine`.
- An optional memory cap that moves older index entries to disk

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
zig-out/bin/sedimentum-bench v1 std /tmp/sdm 1000000     # or v2, v3
zig-out/bin/sedimentum-bench v3 agent /tmp/sdm-agent
cd bench/kiban-bench && cargo build --release
target/release/kiban-bench std /tmp/kiban 1000000
target/release/kiban-bench agent /tmp/kiban-agent
```

`std` is the 13-phase key-value workload; `agent` seeds a million chat
messages and then has 8 agents take turns (load the chat's newest 20
messages, read facts, write two messages, commit). Each run needs a new or
empty directory, prints one JSON line per phase on stdout and a progress
line about once a second on stderr. A fifth argument sets a v1 memory budget
in MB. Results from three 1M-record rounds: Sedimentum was faster
in 9 of 12 workloads; kiban was faster to reopen and to scan everything in key
order.

Licensed under MIT.

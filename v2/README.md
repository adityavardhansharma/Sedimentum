# Sedimentum v2

v2: stream store with a write-ahead log.

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
| Allocation-free reads into your buffer (`getInto`) | no | yes | yes | no |
| RAM stays flat as data grows | with the memory cap | yes | yes | yes |
| C ABI and CLI | yes | yes | yes | Rust only |

v3 makes a batch that touches several streams atomic with a small journal
(`BATCHES`): the batch is written there first, and every shard syncs the
journal before it writes a page or a manifest, so no part of a batch can be
durable before all of it is. On open, any batch operation a stream does not
already hold (by sequence number) is put back, then the journal is emptied.

`compact` copies live data into a fresh file and deletes the old one;
expired values are dropped there and in merges.

## Build and test

```sh
zig build test --summary all
```

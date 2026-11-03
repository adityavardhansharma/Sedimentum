# Crystal (Rust)

A Rust rewrite of Crystal (the Zig engine in `../crystal`). It keeps the same design and adds the four planned fixes and some Rust-only speedups. Accuracy matches the Zig version on every test.

## Run

```
cargo test --release
cargo build --release
./target/release/crystal-bench agent|recall|hard|jargon|lanes [args]
```

The bench is a port of `../crystal/src/bench.zig` and prints the same JSON lines. Results from the cloud run are in `bench-results/`. `CRYSTAL_SYNC=parallel` switches durable writes from group commit to side-by-side flushes.

## What changed from the Zig version

1. **Durable turns.** A background thread grows the lane ahead of the writer, so writers no longer zero-fill and fsync under the lock. Concurrent `sync` callers share one flush (group commit).
2. **Whole-store search.** Posting lists are merged newest-first and counting-sorted instead of a global sort. Rare words are read first. Liveness and scope checks only run on candidates that are actually reached. When memory times are in order, a recency bound skips candidates that can't make the top results.
3. **Reopen.** Open trusts the checksummed snapshot header. Entries are bounds-checked when used, not all at open.
4. **Several writer processes.** Writes no longer refresh other writers' lanes. Reads do.
5. **Rust speedups.** Two interleaved rANS states for texts of 24+ symbols (the decoder runs two independent chains at once; a flag bit in the first state keeps short texts at one state), a scope merge that scans a compact array of list heads, SSE4.2 CRC-32C, a constant stop-word hash table, faster rANS decode (32-byte copies), `memmem` scans, and a build with fat LTO and `target-cpu=native`.

**Finding:** zero-filling the lane in big writes (1 MB, or Zig's 64 KB) makes Linux cache the file in large folios. Each msync then writes back a whole folio for a few changed bytes, so durable turns get about 3× slower. Zero-filling 4 KB at a time fixes it. The Zig version would benefit from the same change.

## Results (same cloud machine)

| Measure | Zig | Rust |
|---|---|---|
| Durable turns | 7,365/s, p99 8.5 ms | 11,811/s, p99 4.05 ms |
| Promised turns | 34,189/s | 36,780/s |
| Agent seed (same-time rerun) | 103k/s | 119–122k/s |
| Recall 1M global p50 | 54.9 µs | 12.7 µs |
| Recall 1M project / brief p50 | 14.1 / 14.6 µs | 8.1 / 9.3 µs |
| Recall 1M recent50 p50 | 52 µs | 39 µs |
| Recall 10M global p50 (p99) | 1.53 ms (2.5 ms) | 78 µs (177 µs) |
| Recall 10M project / brief p50 | 167 / 170 µs | 78 / 62 µs |
| Recall 10M reopen | 1.17 s | 1.01 s |
| Recall 10M load | 151k/s | 161k/s |
| Hard load | 261k/s | 285k/s |
| Hard meaning (project) p50 | 131 µs | 71 µs |
| Jargon queries p50 (same-time rerun) | 10.2–14.4 µs | 6.8–8.2 µs |
| Full scan, 1M / 10M | 0.94 / 9.9 s | 0.65 / 6.6 s |
| Lanes, 1 / 3 / 8 / 32 writers | 206k / 355k / 277k / 109k | 230k / 502k / 486k / 784k |
| Lanes crash, records lost | 0 | 0 |

The machine was replaced between runs, and the newer one has slower disk, so rows marked "same-time rerun" ran Zig and Rust back to back. On that machine durable turns were 6.2k/s for Zig and 8.4–8.9k/s for Rust.

Still slower than Zig: reopen after many writers (32 writers: 0.03 s → 0.41 s) and crash takeover, because fix 4 leaves indexing other lanes to the reader. Two-state coding adds 4 bytes to longer texts (about 2.7% more disk in the 1M recall bench). At 10M, reopen time is almost all the close (writing the snapshot), which is disk-bound.

# Sedimentum holo

Holo: agent memory with recall and briefs, built on v3.

## Holo: memory that briefs the agent

`Holo` (in `src/holo/`) is a different take on agent memory. The other
engines store records an agent fetches by key. Holo answers the question an
agent actually has: "what do I need to know right now?"

```zig
const h = try sdm.Holo.open(gpa, io, dir, "memory", .{});
_ = try h.remember("ledger/chat/42", "we moved the deploy to friday", .{});
_ = try h.remember("ledger/decisions", "auth tokens refresh every 60 minutes", .{ .subject = "auth-refresh" });

const hits = try h.recall(gpa, .{ .about = "when do we deploy?", .scope = "ledger" });
const b = try h.brief(gpa, "user asks why login keeps expiring", "ledger", 2000); // fits 2000 tokens
```

- **remember / recent / current / get / forget / forgetScope / settle**
- **recall** ranks memories by how much of the question they match, then by
  recency; "ledger" covers every scope under it.
- **brief** packs the relevant and the recent memories into a token budget.
- **Sedimentation:** a newer memory with the same subject buries the old one;
  a near-copy of a recent memory buries the copy; among equally good answers
  the newest wins and the older ones drop out of briefs; `settle` adds a
  summary and sinks what it covers. Buried memories stay reachable with `deep`.

How it stays small: each memory keeps its 32 rarest terms as 16-bit tags in a
96-byte row on disk. Every 128 rows share one 4096-bit page fingerprint, and
those fingerprints (about 4 bytes per memory) are the only per-memory data in
RAM. A question checks page fingerprints first and opens only pages that
could score high enough. Text lives in a v3 store; rows, fingerprints and the
rest are checkpointed and rebuilt from the store after a crash.

**Meaning (optional).** Load `models/holo-words.bin` (50,000 English word
stems from ConceptNet Numberbatch, 16 MB) and pass it as `.meaning`:

```zig
const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "models/holo-words.bin", gpa, .unlimited);
const words = try sdm.Holo.Meaning.load(gpa, bytes);
const h = try sdm.Holo.open(gpa, io, dir, "memory", .{ .meaning = words });
```

A question then also looks for related words ("outage" finds "downtime"),
and candidates are reranked by how close their words are in meaning to the
question's. Nothing is stored per memory. `Query.expand = false` turns it off
for one query.

**Bulk writes.** `rememberMany` tokenizes and stores on every core.

Limits: the word table covers common English; names and jargon outside it
match by spelling only. Picking the single right fact among many about the
same name, when the question uses other words, is still hard (see the hard
benchmark).

Benchmarks: `zig-out/bin/sedimentum-holo-bench <agent|recall|hard> <new-dir> [memories] [meaning-model]`.
`hard` stores 20 facts per name in English chat filler and asks each in the
fact's words and in other words, with and without meaning.

## Build and test

```sh
zig build test --summary all
```

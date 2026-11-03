# Sedimentum crystal

Crystal: agent memory that keeps what is true, built from scratch on flat
arrays. Same API as Holo and Stratum (`remember`, `rememberMany`, `recall`,
`brief`, `recent`, `current`, `get`, `forget`, `forgetScope`, `settle`,
`sync`, `promise`, `waitDurable`, `info`, `scanAll`), and it runs the same
benchmark driver unchanged.

## How it works

Every memory is an ordinal, every word is a number, and everything else is a
flat array indexed by one of the two. Nothing in RAM is a pointer, a tree or
a cache.

- **Words are numbers.** A word of up to 12 letters or digits is stored as
  its own base-37 number in a u64: exact, reversible, no collisions, in the
  same order as the words sort (`src/words.zig`).
- **Lexicon.** Word -> term, in one open-addressing table. A word seen once
  keeps its one memory inside its table slot and costs nothing else; on its
  second sighting it becomes a term with a count and postings. A term's
  count is also its weight: a word seen c times in N memories carries
  log2(N/c) bits, which is what recall credits it.
- **Postings.** Per term and per scope, the ordinals that contain it, in
  blocks that double from 2 to 1024 entries, read newest first. A word too
  common to carry 10 bits keeps no postings at all: it can only confirm a
  match, never find one. When every question word is findable, recall
  scores candidates from postings and record headers alone and decodes only
  the winners.
- **Facts.** Every version of a fact joins one cell, and the cell names its
  newest version, which is the only one recall and briefs answer with.
  Versions join by subject, or when written, by the shape of the claim: the
  same name (a rare word seen before), a new value (a word never seen), and
  the same slot (the words between the name and its value, by spelling or
  meaning), or a change word ("now", "moved", "became") when the name has
  one fact. A memory with two never-seen words (a new name and its value)
  is a new fact, unless it says it changes something about a name seen only
  a few times.
- **Lanes.** One append-only file per writer process, the only source of
  truth, with checksums, torn tails cut on open, and erased text overwritten
  with zeros. Text is coded with rANS over a word model each writer learns
  from its own memories (`src/ans.zig`). Several processes write one store,
  each in its own lane; forgets carry the lane ends their writer had seen,
  so they cover exactly what happened before them.
- **Snapshot.** At close every index array is written page-aligned, and
  opening maps it back copy-on-write and reads only the records after it.
- **Durability.** Writes go into a mapped lane; `sync` flushes from the last
  durable byte, side by side with other writers. With `.flusher = true`,
  writes return at once and a background thread flushes whole pages while
  writes keep coming, and the last page when they pause.

Meaning (optional) uses the same word table as Holo and Stratum
(`../stratum/models/holo-words.bin`, CC BY-SA 4.0), loaded with Crystal's
own loader (`src/Meaning.zig`). It is not copied into this folder.

## Build, test, benchmark

Requires Zig 0.17.0. No other dependencies.

```sh
zig build test --summary all
zig build -Doptimize=ReleaseFast
zig-out/bin/crystal-bench <agent|recall|hard|jargon|lanes> <new-dir> [memories] [meaning-model]
zig-out/bin/crystal-flushbench <each|leader|fdatasync> <file>    # the disk alone (Linux)
```

`src/bench.zig` is Stratum's benchmark driver with only the engine changed,
so every workload is byte for byte the same. Raw outputs of the run below
are in `bench-results/`.

## Results

Crystal, 3 Nov, against the Stratum numbers from the 2 Nov rerun (Stratum
was not rerun). 1M memories, AMD Ryzen 9 4900HS, btrfs. Every benchmark
finished in under 40 seconds.

**Finding old facts** (1 fact per 500 messages, 30% changed later)

| Measure                              | Crystal          | Stratum         |
|:-------------------------------------|-----------------:|----------------:|
| Right at #1, whole store             | 100%             | 100%            |
| Whole store p50 / p99                | 0.044 / 0.111 ms | 0.12 / 0.34 ms  |
| One project p50 / p99                | 0.016 / 0.027 ms | 0.05 / 0.08 ms  |
| Brief has the answer / an old value  | 100% / 0%        | 100% / 0%       |
| Load (memories per second)           | 198k             | 100k            |
| RAM after reopening (anon)           | 3.4 MB           | 14 MB           |
| Disk                                 | 123 MB           | 280 MB          |

**Questions in other words** (20 facts per name, 30% changed later)

| Question, search          | Crystal #1 / top 5 | p50      | Stratum #1 / top 5 | p50    |
|:--------------------------|-------------------:|---------:|-------------------:|-------:|
| Same words, words only    | 93.6% / 94.8%      | 0.069 ms | 87.4% / 92.2%      | 1.2 ms |
| Same words, with meaning  | 93.6% / 97.9%      | 0.165 ms | 87.5% / 97.9%      | 1.9 ms |
| Other words, words only   | 10.2% / 29.0%      | 0.042 ms | 8.0% / 26.1%       | 1.2 ms |
| Other words, with meaning | 23.7% / 71.8%      | 0.075 ms | 20.2% / 64.4%      | 1.9 ms |
| Brief has the answer      | 93.9% (old 3.5%)   | 0.084 ms | 91.4% (old 11.3%)  | 1.0 ms |

Disk 116 MB (Stratum 218 MB).

**Project jargon restated over time**

| Facts          | Crystal #1 / top 5 / old at #1 | p50 / p99   | Stratum #1 / top 5 / old at #1 | p50 / p99   |
|:---------------|-------------------------------:|------------:|-------------------------------:|------------:|
| With a subject | 100% / 100% / 0%               | 11 / 24 µs  | 100% / 100% / 0%               | 8 / 36 µs   |
| No subject     | 99.6% / 100% / 0.45%           | 11 / 20 µs  | 26.8% / 99.9% / 73.3%          | 13 / 48 µs  |

**Agent workload** (1M messages, then 8 threads, 40,000 turns)

| Measure                         | Crystal          | Stratum          |
|:--------------------------------|-----------------:|-----------------:|
| Turns/s, promised               | 33,159           | 33,800           |
| p50 / p99, promised             | 0.10 / 1.5 ms    | 0.056 / 3.3 ms   |
| Turns/s, every turn durable     | 1,364            | 8,460            |
| Brief p50                       | 0.64 ms          | 1.03 ms          |
| RAM after reopening (anon)      | 9.3 MB           | 12 MB            |
| Disk                            | 186 MB           | 308 MB           |
| Reopen                          | 0.06 s           | 0.76 s           |

**Several writer processes** (20,000 memories each, a sync every 64)

| Writers | Crystal writes/s | Stratum writes/s | Lost | Garbled |
|--------:|-----------------:|-----------------:|-----:|--------:|
| 1       | 25k              | 178k             | 0    | 0       |
| 3       | 43k              | 414k             | 0    | 0       |
| 8       | 99k              | 522k             | 0    | 0       |
| 32      | 141k             | 84k              | 0    | 0       |

Crash test: 8 writers killed with `kill -9`; all 149,632 confirmed writes
were there afterwards, plus 512 unconfirmed, nothing garbled, and 8 new
writers took over the dead lanes with nothing lost.

## Limits

- **Durable writes are bound by the disk, which was slower on this run.**
  `crystal-flushbench` on the same disk, with no store at all, managed only
  about 2,000 durable turns per second (2,471 when flushes are grouped).
  Crystal reached 1,364, about 70% of that while also reading 20 messages
  and briefing every turn. Stratum's 8,460 turns/s and its 178k writes/s
  per writer were measured on a disk doing 15,000 to 18,000 flushes per
  second. Both rows need a rerun of both engines on one disk to compare.
- **Questions in other words are bound by the word table.** Ranking the 20
  fact templates against each paraphrase by word meaning alone, with no
  chatter at all, puts the right one first for 7 of 20 questions (35%) and
  in the top 5 for 16 (80%). Crystal reaches 23.7% at #1 and 71.8% in the
  top 5. Getting past that needs more knowledge than the table holds, not a
  better index. "Other words, words only" shares no word with the answer
  and cannot be found by any engine.
- **Same words at 93.6%:** updates that share no word with their fact and
  whose slot words the table does not connect stay separate (4.2% stale).
- Promised turns are bound by CPU, about 105 µs per turn on this machine.

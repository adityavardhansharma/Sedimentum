# Sedimentum loom

Loom: agent memory that learns its own schema from what it is told. Same API
as Crystal, Holo and Stratum (`remember`, `rememberMany`, `recall`, `brief`,
`recent`, `current`, `get`, `forget`, `forgetScope`, `settle`, `sync`,
`promise`, `waitDurable`, `info`, `scanAll`), plus `schema()` and `facts(name)`,
and it runs the same benchmark driver unchanged.

## The idea

Every earlier engine decides, one memory at a time, whether a new memory
continues an old one: Crystal links a claim when it is written, by its
shape. That decision is made with what one memory says, so it guesses.

Loom does not link anything when it is written. It keeps the memories that
state something (claims) and, in the background, works out from all of them
together what kinds of things the store is told about, and who they are
told about. The result is a table the store built for itself:

```
             region      deploy      retention   pager       ...
atlas        eu-west-1   friday      30 days     priya
borealis     us-east-2   -           90 days     sam
...
```

Each cell holds every claim that ever stated that attribute of that name,
and the newest one is the current value. Recall answers with a cell's
newest claim, a brief adds the row of every name it is about, and
`loom-schema` prints the attributes the store found, with no list of them
given anywhere.

### How the table is learned (`src/Weave.zig`)

1. **Claims.** A memory with two rare words, or a subject and one rare
   word. Its value is its rarest word.
2. **Wording, by place-keeping.** A word that sits at the same place
   relative to the value in many claims ("keeps logs for **X**", "**X** is
   backed up every") is wording; a word that turns up at any place (a name,
   chatter) is not. Each claim's wording is its set of (word, offset from
   the value) pairs that keep their place. This is the step that tells
   template from content without being told either.
3. **Frames.** Claims cluster on their wording (leader clustering, cosine
   0.75). A frame is one way of saying one kind of thing. Frames smaller
   than 4 claims have learned nothing and are split into single claims.
4. **Slots.** Frames are joined into attributes on evidence, never on
   similar words: claims a writer tied with one subject; a frame that says
   something changed ("slipped", "moved", "now") joins the one slot its
   names were all stated in before; and a one-off claim no frame explains,
   and no subject placed, joins the earlier claim it shares the most words
   with, when that claim is the only one that close.
5. **Grid.** Each claim's names are its rare words that are not wording.
   Cell = (slot, name). A claim's newest version is the newest claim of its
   cells, unless a writer's subject says otherwise.

The weave is rebuilt from scratch, off the write path, when the claims have
grown by an eighth, and swapped in atomically; readers go on with the one
they hold, and the writer frees replaced ones when no reader is in. A claim
costs its 4-byte ordinal; the weave reads its words back from the text.

Recall also matches a question against a slot's pooled wording, not only
the words of one memory, so a question worded like any of a slot's frames
finds that slot's claims.

### What is new and what is not

New here, as far as I know, for agent memory: learning the attribute
schema of a memory store from its own contents, continuously, and using the
learned (name, attribute) cell as the unit of truth for recall and briefs;
and telling wording from content by whether a word keeps its place relative
to the value.

Not new, and worth reading next to it: log template mining (Drain, Spell)
learns templates from logs the same way frames are learned here; Open
Information Extraction and Universal Schema (Riedel et al., 2013) learn
relations from text without a fixed schema. Loom borrows their spirit, not
their code. Leader clustering, union-find and cosine similarity are
textbook.

Taken unchanged from Crystal: lanes, records, durability, postings, scopes,
snapshots (`src/Loom.zig`, minus Crystal's write-time linking),
`src/words.zig`, `src/ans.zig`, `src/Meaning.zig` and
`tools/flushbench.zig`. Meaning uses the same word table as Holo, Stratum
and Crystal (`../stratum/models/holo-words.bin`, CC BY-SA 4.0), which is not
copied into this folder.

## Build, test, benchmark

Requires Zig 0.17.0. No other dependencies.

```sh
zig build test --summary all
zig build -Doptimize=ReleaseFast
zig-out/bin/loom-bench <agent|recall|hard|jargon|lanes> <new-dir> [memories] [meaning-model]
zig-out/bin/loom-schema <store-dir> [name] [slots-to-show]    # what the store learned
zig-out/bin/loom-flushbench <each|leader|fdatasync> <file>
```

`src/bench.zig` is Crystal's benchmark driver with only the engine changed.
Raw outputs are in `bench-results/` (Loom as `<mode>.json`, Crystal rerun
on the same machine as `crystal-<mode>.json`; agent and lanes as three runs,
`-r1` to `-r3`).

## Results

17 Nov, Loom against Crystal, both run on the same machine the same day:
4 vCPU, ext4. 1M memories unless it says 10M. Agent and lanes ran three
times each; their numbers are the middle run, and the noise between runs is
a few percent.

**Questions in other words** (20 facts per name, 30% changed later)

| Question, search          | Loom #1 / top 5 / old  | Crystal #1 / top 5 / old | Loom p50 | Crystal p50 |
|:--------------------------|-----------------------:|-------------------------:|---------:|------------:|
| Same words, words only    | 99.15% / 99.2% / 0.05% | 93.6% / 94.8% / 4.2%     | 14 µs    | 43 µs       |
| Same words, with meaning  | 99.15% / 99.2% / 0.05% | 93.55% / 97.9% / 4.2%    | 36 µs    | 170 µs      |
| Other words, words only   | 14.05% / 31.7% / 0%    | 10.2% / 29.0% / 0.05%    | 12 µs    | 38 µs       |
| Other words, with meaning | 28.05% / 77.6% / 0%    | 23.7% / 71.8% / 0.55%    | 21 µs    | 74 µs       |
| Brief has the answer      | 99.2% (old 1.0%)       | 93.9% (old 3.5%)         | 36 µs    | 83 µs       |
| Brief, words only         | 99.2% (old 1.0%)       | 77.9% (old 1.8%)         | 26 µs    | 47 µs       |
| Brief size (tokens)       | 595                    | 629                      |          |             |
| Load, memories/s          | 353k                   | 293k                     |          |             |

**The same at 10M** (1,000 names, 20,000 facts)

| Question, search          | Loom #1 / old    | p50     | Crystal #1 / old | p50     |
|:--------------------------|-----------------:|--------:|-----------------:|--------:|
| Same words, words only    | 98.15% / 0%      | 0.04 ms | 90.55% / 6.45%   | 0.10 ms |
| Same words, with meaning  | 98.15% / 0%      | 0.24 ms | 90.7% / 6.4%     | 0.88 ms |
| Other words, words only   | 12.35% / 0%      | 0.03 ms | 8.25% / 0.15%    | 0.06 ms |
| Other words, with meaning | 27.05% / 0%      | 0.04 ms | 22.3% / 0.45%    | 0.11 ms |
| Brief has the answer      | 98.25% (old 1.75%) | 0.05 ms | 93.7% (old 5.2%) | 0.11 ms |
| Load, memories/s          | 375k             |         | 326k             |         |

**Finding old facts** (1 fact per 500 messages, 30% changed later)

| Measure                           | Loom              | Crystal           |
|:----------------------------------|------------------:|------------------:|
| Right at #1, whole store (1M/10M) | 100% / 99.9%      | 100% / 99.9%      |
| Right at #1, one project (1M/10M) | 100% / 99.95%     | 100% / 100%       |
| Whole store p50, 1M / 10M         | 42-45 µs / 1.15 ms | 40-41 µs / 1.25 ms |
| One project p50, 1M / 10M         | 12 / 132 µs       | 12 / 130 µs       |
| Brief p50, 1M / 10M               | 13 / 134 µs       | 12 / 132 µs       |
| Brief size (tokens), 1M / 10M     | 45 / 66           | 70 / 103          |
| RAM after queries (anon), 1M/10M  | 4.2 / 12.1 MB     | 3.4 / 6.3 MB      |
| Disk, 1M / 10M                    | 123 MB / 1.09 GB  | 123 MB / 1.09 GB  |

**Project jargon restated over time** (made-up words, three synonyms per setting)

| Facts          | Loom #1 / old at #1 | p50   | Crystal #1 / old at #1 | p50   |
|:---------------|--------------------:|------:|-----------------------:|------:|
| With a subject | 100% / 0%           | 2 µs  | 100% / 0%              | 8 µs  |
| No subject     | 100% / 0%           | 2 µs  | 99.55% / 0.45%         | 8 µs  |
| Brief          | 100% (old 0.05%)    | 3 µs  | 100% (old 0.3%)        | 8 µs  |

**Agent workload** (1M messages, then 8 threads, 40,000 turns)

| Measure                       | Loom          | Crystal       |
|:------------------------------|--------------:|--------------:|
| Seed, messages/s              | 140k          | 132k          |
| Turns/s, every turn durable   | 8,260-8,490   | 8,370-8,540   |
| Turns/s, promised             | 37,800-39,900 | 37,500-38,600 |
| Brief p50                     | 0.44-0.50 ms  | 0.43-0.45 ms  |
| RAM during turns (anon)       | 63 MB         | 63 MB         |
| RAM after reopening (anon)    | 9.9 MB        | 9.7 MB        |
| Reopen                        | 0.10 s        | 0.11 s        |
| Disk                          | 186 MB        | 186 MB        |

**Several writer processes** (20,000 memories each, a sync every 64)

| Writers | Loom writes/s | Crystal writes/s | Lost | Garbled |
|--------:|--------------:|-----------------:|-----:|--------:|
| 1       | 256k          | 225k             | 0    | 0       |
| 3       | 412k          | 372k             | 0    | 0       |
| 8       | 363k          | 318k             | 0    | 0       |
| 32      | 137k          | 135k             | 0    | 0       |

Disk and peak heap are the same as Crystal's in every lanes run. Crash
test: 8 writers killed with `kill -9`; every confirmed write was there
afterwards in all three runs (up to 1,116,928), nothing garbled, and new
writers took over the dead lanes with nothing lost.

## Limits and tradeoffs

- **Where Crystal is still ahead, slightly.** Whole-store recall over chat
  at 1M is 2-4 µs slower (about 1.5 µs of it is reading the learned
  table); briefs over chat are about 1 µs slower; the agent brief p50 is
  0-10% slower and durable turns/s are within noise of each other. One
  question in 2,000 is missed at 10M in one project (99.95%).
- **The weave costs a little RAM.** It lives in memory, is rebuilt rather
  than persisted, and reads only the newest 131,072 claims, so its size
  is bounded however large the store grows (older claims answer as
  themselves and by subject). After queries: 4.2 MB at 1M (Crystal 3.4),
  12.1 MB at 10M (6.3). Its arenas go back to the OS when a weave is
  replaced, so a reopened agent store holds 9.9 MB (9.7).
- **Writing a large store in one session uses more RAM than 80 MB, for
  both engines.** The per-memory vectors are heap while a session writes
  and are mapped from the snapshot after it reopens: about 37 MB while
  loading 1M, 222 MB while loading 10M, 63 MB during the agent run. This
  is the substrate Loom shares with Crystal, not the weave.
- **A schema needs repetition.** A kind of fact stated fewer than 4 times
  in one wording learns nothing until a subject, a change word or a shared
  name joins it to something; until then it is answered as its own memory,
  the way Crystal would.
- **Newest wins.** A cell's current value is its newest claim. A memory
  that restates an old value as history ("it used to be X") can win its
  cell.
- **Other words, words only** shares no word with the answer and cannot be
  found by any engine; other words with meaning is bound by the word
  table, as it is for Crystal.

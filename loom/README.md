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
on the same machine as `crystal-<mode>.json`).

## Results

16 Nov, Loom against Crystal, both run on the same machine the same day:
8 vCPU Xeon at 2.3 GHz, ext4. 1M memories unless it says 10M.

**Questions in other words** (20 facts per name, 30% changed later)

| Question, search          | Loom #1 / top 5 / old | Crystal #1 / top 5 / old |
|:--------------------------|----------------------:|-------------------------:|
| Same words, words only    | 97.8% / 98.3% / 0.4%  | 93.6% / 94.8% / 4.2%     |
| Same words, with meaning  | 97.8% / 98.3% / 0.4%  | 93.6% / 97.9% / 4.2%     |
| Other words, words only   | 9.8% / 28.4% / 0%     | 10.2% / 29.0% / 0.05%    |
| Other words, with meaning | 23.9% / 75.6% / 0%    | 23.7% / 71.8% / 0.55%    |
| Brief has the answer      | 98.8% (old 1.2%)      | 93.9% (old 3.5%)         |
| Brief, words only         | 98.7% (old 1.2%)      | 77.9% (old 1.8%)         |
| Brief size (tokens)       | 789                   | 629                      |
| Load, memories/s          | 333k                  | 275k                     |

**The same at 10M** (1,000 names, 20,000 facts)

| Question, search          | Loom #1 / old  | p50     | Crystal #1 / old | p50     |
|:--------------------------|---------------:|--------:|-----------------:|--------:|
| Same words, words only    | 97.2% / 1.0%   | 0.10 ms | 90.6% / 6.5%     | 0.17 ms |
| Same words, with meaning  | 97.2% / 1.0%   | 0.54 ms | 90.7% / 6.4%     | 1.07 ms |
| Other words, with meaning | 23.0% / 0.05%  | 0.09 ms | 22.3% / 0.45%    | 0.15 ms |
| Brief has the answer      | 98.3% (old 1.8%) | 0.12 ms | 93.7% (old 5.2%) | 0.15 ms |
| Load, memories/s          | 350k           |         | 280k             |         |

**Finding old facts** (1 fact per 500 messages, 30% changed later)

| Measure                          | Loom              | Crystal           |
|:---------------------------------|------------------:|------------------:|
| Right at #1, whole store (1M/10M)| 100% / 99.9%      | 100% / 99.9%      |
| Whole store p50, 1M / 10M        | 0.047 / 1.34 ms   | 0.058 / 1.62 ms   |
| One project p50, 1M / 10M        | 0.012 / 0.157 ms  | 0.012 / 0.145 ms  |
| RAM after queries (anon), 1M/10M | 10.8 / 70 MB      | 3.4 / 6.3 MB      |
| Disk, 1M / 10M                   | 123 MB / 1.09 GB  | 123 MB / 1.09 GB  |

**Project jargon restated over time** (made-up words, three synonyms per setting)

| Facts          | Loom #1 / old at #1 | Crystal #1 / old at #1 |
|:---------------|--------------------:|-----------------------:|
| With a subject | 99.8% / 0%          | 100% / 0%              |
| No subject     | 98.95% / 1.0%       | 99.55% / 0.45%         |

**Agent workload** (1M messages, then 8 threads, 40,000 turns)

| Measure                       | Loom          | Crystal       |
|:------------------------------|--------------:|--------------:|
| Turns/s, every turn durable   | 8,350         | 7,516         |
| Turns/s, promised             | 41,387        | 37,033        |
| Brief p50                     | 0.46 ms       | 0.48 ms       |
| RAM after reopening (anon)    | 45 MB         | 9.5 MB        |
| Reopen                        | 0.107 s       | 0.124 s       |
| Disk                          | 186 MB        | 186 MB        |

**Several writer processes** (20,000 memories each, a sync every 64)

| Writers | Loom writes/s | Crystal writes/s | Lost | Garbled |
|--------:|--------------:|-----------------:|-----:|--------:|
| 1       | 225k          | 241k             | 0    | 0       |
| 3       | 377k          | 447k             | 0    | 0       |
| 8       | 329k          | 309k             | 0    | 0       |
| 32      | 148k          | 137k             | 0    | 0       |

Crash test: 8 writers killed with `kill -9`; all 1,052,096 confirmed writes
were there afterwards, nothing garbled, and new writers took over the dead
lanes with nothing lost.

## Limits and tradeoffs

- **The weave costs RAM.** The learned table lives in memory: 10.8 MB
  after queries at 1M (Crystal 3.4 MB), 70 MB at 10M (6.3 MB), 45 MB after
  reopening the agent store (9.5 MB). It is rebuilt, not persisted, so the
  first query after opening builds it. Building it is a burst of heap
  (8.8 MB peak at 1M hard, 48 MB at 10M, and about 57 MB per process in the
  lanes test, where every memory is a claim).
- **Briefs are larger** (789 tokens against 629) because they carry the
  rows of the names they are about. That is where most of their gain comes
  from.
- **Jargon with no subject is slightly worse** (98.95% against 99.55%).
  When names are common words and the settings are made-up, the place a
  value is stated is less telling than Crystal's write-time rule.
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

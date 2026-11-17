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

Taken from Crystal: lanes, records, durability, postings, scopes,
snapshots (`src/Loom.zig`, minus Crystal's write-time linking),
`src/words.zig` (plus byte offsets), `src/ans.zig`, `src/Meaning.zig` and
`tools/flushbench.zig`.

### Where the index lives while a writer runs

Crystal keeps a writer's whole index (postings, timeline, hash tables) in
anonymous memory until the store is closed: about 220 MB while 10M
memories are written in one session, and a reopened store's snapshot,
mapped copy-on-write, turns every page a writer touches into anonymous
memory again (48 MB after the agent run's 40,000 turns). Loom gives every
index array and table a stretch of an unnamed scratch file (`O_TMPFILE`
in the store's folder, gone with the process). An index starts in plain
memory; past 32 MB, or before the first write to a reopened one, it is
written into its stretches and mapped from there (`Backing` and `adopt`
in `src/Loom.zig`), so the kernel writes those pages out and drops them as
it needs to. Readers see the same bytes throughout. Without `O_TMPFILE`
it stays in plain memory, as Crystal does. Meaning uses the same word table as Holo, Stratum
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
times each; their numbers are the median run, and runs differ by up to 10%.
Anonymous memory (anon) is the process's RssAnon: the memory that is not a
file the kernel can write out and drop.

**Questions in other words** (20 facts per name, 30% changed later)

| Question, search          | Loom #1 / top 5 / old  | Crystal #1 / top 5 / old | Loom p50 | Crystal p50 |
|:--------------------------|-----------------------:|-------------------------:|---------:|------------:|
| Same words, words only    | 99.15% / 99.2% / 0.05% | 93.6% / 94.8% / 4.2%     | 20 µs    | 68 µs       |
| Same words, with meaning  | 99.15% / 99.2% / 0.05% | 93.55% / 97.9% / 4.2%    | 51 µs    | 214 µs      |
| Other words, words only   | 14.05% / 31.7% / 0%    | 10.2% / 29.0% / 0.05%    | 16 µs    | 48 µs       |
| Other words, with meaning | 28.05% / 77.6% / 0%    | 23.7% / 71.8% / 0.55%    | 26 µs    | 104 µs      |
| Brief has the answer      | 100% (old 1.0%)        | 93.9% (old 3.5%)         | 45 µs    | 110 µs      |
| Brief, words only         | 99.7% (old 1.0%)       | 77.9% (old 1.8%)         | 33 µs    | 57 µs       |
| Brief size (tokens)       | 595                    | 629                      |          |             |
| Load, memories/s          | 305k                   | 239k                     |          |             |

**The same at 10M** (1,000 names, 20,000 facts)

| Question, search          | Loom #1 / old      | p50     | Crystal #1 / old | p50     |
|:--------------------------|-------------------:|--------:|-----------------:|--------:|
| Same words, words only    | 98.15% / 0%        | 0.06 ms | 90.55% / 6.45%   | 0.12 ms |
| Same words, with meaning  | 98.15% / 0%        | 0.34 ms | 90.7% / 6.4%     | 0.99 ms |
| Other words, words only   | 12.35% / 0%        | 0.04 ms | 8.25% / 0.15%    | 0.08 ms |
| Other words, with meaning | 27.05% / 0%        | 0.06 ms | 22.3% / 0.45%    | 0.14 ms |
| Brief has the answer      | 100% (old 1.75%)   | 0.12 ms | 93.7% (old 5.2%) | 0.13 ms |
| Load, memories/s          | 315k               |         | 268k             |         |

**Finding old facts** (1 fact per 500 messages, 30% changed later)

| Measure                            | Loom              | Crystal           |
|:-----------------------------------|------------------:|------------------:|
| Right at #1, whole store (1M/10M)  | 100% / 99.9%      | 100% / 99.9%      |
| Right at #1, one project (1M/10M)  | 100% / 100%       | 100% / 100%       |
| Brief has the answer (1M/10M)      | 100% / 100%       | 100% / 100%       |
| Whole store p50, 1M / 10M          | 53 µs / 1.46 ms   | 50 µs / 1.41 ms   |
| One project p50, 1M / 10M          | 14.0 / 159 µs     | 14.1 / 160 µs     |
| Brief p50, 1M / 10M                | 16.0 / 157 µs     | 16.7 / 160 µs     |
| Brief size (tokens), 1M / 10M      | 45 / 66           | 70 / 103          |
| Anon after loading, 1M / 10M       | 37.7 / 6.2 MB     | 37.8 / 222 MB     |
| Anon after queries, 1M / 10M       | 4.2 / 12.0 MB     | 3.4 / 6.3 MB      |
| Disk, 1M / 10M                     | 123 MB / 1.09 GB  | 123 MB / 1.09 GB  |

**Project jargon restated over time** (made-up words, three synonyms per setting)

| Facts          | Loom #1 / old at #1 | p50   | Crystal #1 / old at #1 | p50   |
|:---------------|--------------------:|------:|-----------------------:|------:|
| With a subject | 100% / 0%           | 2 µs  | 100% / 0%              | 9 µs  |
| No subject     | 100% / 0%           | 2 µs  | 99.55% / 0.45%         | 9 µs  |
| Brief          | 100% (old 0.05%)    | 4 µs  | 100% (old 0.3%)        | 10 µs |

**Agent workload** (1M messages, then 8 threads, 40,000 turns)

| Measure                       | Loom          | Crystal       |
|:------------------------------|--------------:|--------------:|
| Seed, messages/s              | 117k          | 104k          |
| Turns/s, every turn durable   | 7,260         | 6,783         |
| Turns/s, promised             | 39,798        | 32,262        |
| Brief p50                     | 0.53 ms       | 0.54 ms       |
| Anon while seeding            | 2.7 MB        | 57.6 MB       |
| Anon during durable turns     | 6.4 MB        | 62.7 MB       |
| Anon during promised turns (reopened) | 11.7 MB | 48.3 MB    |
| Anon after reopening          | 10.0 MB       | 9.6 MB        |
| Reopen                        | 0.12 s        | 0.13 s        |
| Disk                          | 186 MB        | 186 MB        |

**Several writer processes** (20,000 memories each, a sync every 64)

| Writers | Loom writes/s | Crystal writes/s | Lost | Garbled |
|--------:|--------------:|-----------------:|-----:|--------:|
| 1       | 191k          | 186k             | 0    | 0       |
| 3       | 310k          | 368k             | 0    | 0       |
| 8       | 294k          | 290k             | 0    | 0       |
| 32      | 114k          | 129k             | 0    | 0       |

Disk is the same as Crystal's in every lanes run. Crash test: 8 writers
killed with `kill -9`; every confirmed write was there afterwards in all
three runs, nothing garbled, and new writers took over the dead lanes with
nothing lost.

## Limits and tradeoffs

- **Where Crystal is still ahead.** Whole-store recall over chat is 3 µs
  (6%) slower at 1M and 3% at 10M; both engines read the same 128
  candidates a question, and the learned table's lookups were measured not
  to be the cause. Several writer processes write 5-12% slower at 3 and 32
  writers (and on par at 1 and 8); runs differ by up to 10%, but the gap
  held across three runs. Anon after queries is a few MB higher (4.2
  against 3.4 MB at 1M, 12.0 against 6.3 at 10M): the learned table.
- **The weave lives in memory**, is rebuilt rather than persisted, and
  reads only the newest 131,072 claims, so its size is bounded however
  large the store grows (older claims answer as themselves and by
  subject). Its arenas go back to the OS when a weave is replaced.
- **The scratch file is disk.** A writer's index pages are written to it
  as the kernel sees fit, so a large write session does disk I/O Crystal
  would hold in memory. It is unnamed and goes with the process; it is
  never read back after a crash (the snapshot and the lanes are the
  durable state, as before).
- **A schema needs repetition.** A kind of fact stated fewer than 4 times
  in one wording learns nothing until a subject, a change word or a shared
  name joins it to something; until then it is answered as its own memory,
  the way Crystal would.
- **Newest wins.** A cell's current value is its newest claim (in the
  scope asked). A memory that restates an old value as history ("it used
  to be X") can win its cell.
- **Other words, words only** shares no word with the answer and cannot be
  found by any engine; other words with meaning is bound by the word
  table, as it is for Crystal.

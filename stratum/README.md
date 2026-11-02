# Sedimentum stratum

Stratum: one fact over its whole life, promised turns; the newest approach.

## Stratum: one fact over its whole life

`Stratum` (in `src/stratum/`) has the same API as Holo (`remember`,
`rememberMany`, `recall`, `brief`, `current`, `recent`, `forget`,
`forgetScope`, `settle`, `info`, `scanAll`), but it indexes facts instead of
records. Every version of a fact joins one *stratum*, either through a shared
`subject` or automatically, when a new memory shares at least three rare words
with an older one in the same scope. A question that matches any version of a
fact gets the newest version back, so an old wording still finds the
current value.

- **Several writers at once.** Each process that opens the store claims its
  own lane file (`lane-NNN.sdm`) with a file lock, and only ever appends to it.
  Readers pick up the other lanes every 20 ms. Writers never wait for each
  other, and a crashed writer's lane is taken over by the next one to open.
- **Small in RAM.** Each word keeps a head pointer per lane, and every record
  links back to the previous record with the same word, so a question walks
  short chains on disk. At 10M memories, RAM after reopen is about 16 MB.
- **Crash safe.** Every record has a checksum, a torn tail is cut off on
  open, and erased text is overwritten with zeros.
- **Small on disk.** Each lane learns its writers' words: a word seen twice
  gets a 1 or 2 byte code, written down once in the lane so every reader
  decodes the same text. Records have a 56-byte header, and word links are
  3-byte keys plus short distances.
- **No read locks.** Readers never wait for the writer; each turn's write is
  flushed on its own range of the file, so durable turns don't queue behind
  one flusher.
- **Promised turns.** Open with `.flusher = true` and a write returns as soon
  as it is in the lane, whatever `sync_writes` says; a background thread
  makes it durable. `promise()`
  names everything written so far, `isDurable(p)` checks it and
  `waitDurable(p)` waits for it, so an agent waits for the disk only before
  it acts outside (sends a message, calls a tool). Threads that write at the
  same time hand their memories to one writer, which appends them together.

Benchmarks: `zig-out/bin/sedimentum-stratum-bench` takes the same modes as
the Holo bench, plus `jargon` (project words that change value over time) and
`lanes` (1 to 32 writer processes, plus a `kill -9` crash test).
`.holo-report/stratum.html` has the results.

Agent workload (1M messages, 8 threads, every turn durable unless promised),
same machine:

| Engine                  | Turns/s | p99    | RAM after reopen | Disk   |
|-------------------------|--------:|-------:|-----------------:|-------:|
| Stratum, promised turns |  33,800 | 3.3 ms |            12 MB | 308 MB |
| Stratum                 |   8,460 | 5.6 ms |            12 MB | 308 MB |
| Holo                    |   5,713 | 6.8 ms |            32 MB | 408 MB |
| v3                      |   7,214 | 3.2 ms |            88 MB | 391 MB |
| v1                      |   7,750 | 2.8 ms |           229 MB | 587 MB |

With promised turns a turn takes 56 µs at the median and is durable about
3 ms later; the turns are then bound by CPU (about 100 µs per turn on this
4-core machine), not by the disk. Limits: when every turn must be durable
before it returns, turns are bound by the disk's flush rate. Versions with no subject and too few rare words in
common stay separate, and questions in other words need the meaning table:
there Stratum matches Holo, it doesn't beat it.

## Build and test

```sh
zig build test --summary all
```

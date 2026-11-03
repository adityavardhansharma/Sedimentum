# Sedimentum

Embedded storage for agent memory, written in Zig. Each engine has its own
folder, and each folder is a standalone Zig project with its own tests and
README:

| Folder | What it is |
|--------|------------|
| [`v1/`](v1/) | Key-value store: append-only segments, an in-memory index, and a cold index for data larger than RAM. |
| [`v2/`](v2/) | Stream store with a write-ahead log and 64 KB tails in RAM. |
| [`v3/`](v3/) | Stream store with no write-ahead log. It also has the `sedimentum` CLI, the C library and the kiban comparison benchmark, which open every key-value format. |
| [`holo/`](holo/) | Holo: agent memory with recall, sedimentation and token-budgeted briefs, built on v3. |
| [`stratum/`](stratum/) | Stratum: one fact over its whole life, a lane file per writer, and promised turns. |
| [`crystal/`](crystal/) | Crystal, the newest approach: flat arrays, words as numbers, entropy-coded lanes, and facts that link by the shape of their claim. |

The engines share some files (for example, Holo runs on the v3 store), so
each folder carries its own copy of the code it needs. A change to shared
code has to be made in every folder that uses it.

Build and test one engine:

```sh
cd stratum
zig build test --summary all
```

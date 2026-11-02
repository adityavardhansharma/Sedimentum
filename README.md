# Sedimentum

- [`sedimentum-v1/`](sedimentum-v1/): the v1 storage engines (v1, v2, v3,
  Holo and Stratum agent memory), with their CLI, C library, tests and
  benchmarks. See its [README](sedimentum-v1/README.md).

Build and test:

```sh
cd sedimentum-v1
zig build test --summary all
```

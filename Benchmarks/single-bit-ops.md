# Single-bit `write(Bool)` / `readBit()` — specialised path

**Question.** `write(_ bit: Bool)` and `readBit()` forward to the general
width-N core (mask computation, spanning-boundary branch). For bit-at-a-time
workloads, is a dedicated 1-bit path faster?

- **Current:** `write(bit ? 1 : 0, bits: 1)` / `read(bits: 1) != 0`.
- **Alternative:** set/test one bit directly; no mask, no spanning branch.

## What was tested

Both in one module under `-O`; outputs asserted identical (same `data()` after
writing 1000 bits; matching values over a full 4 Mibit read). Timing: 40 M
single-bit ops per measurement, best-of-3, 5 interleaved repeats.

## Results (median, 40 M ops)

| Operation | current | specialised | throughput (cur → alt) |
| --- | --- | --- | --- |
| write bit | ~117.2 ms | ~16.9 ms | 341 → 2360 M ops/s |
| read bit | ~76.5 ms | ~25.1 ms | 523 → 1595 M ops/s |

## Calculation / interpretation

Speedup = 117.2 / 16.9 ≈ **6.9×** (write), 76.5 / 25.1 ≈ **3.0×** (read). A
single bit never spans a word boundary and needs no mask, so the specialised
path drops most of the general core's work.

## Decision

**Adopted** by specialising the existing `write(_ bit: Bool)` and `readBit()` —
no new API, no risk. `readBit()` keeps its throwing bounds check (the benchmark
used a `precondition`); the win comes from removing the mask/spanning work, not
the bounds check, so it holds — re-verified on the committed `write(_ bit:)` at
**~6.3×** vs the general width-1 path. High value for bit-stream-heavy users
(arithmetic/range coding, RLE, bitmaps). All tests pass.

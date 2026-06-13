# `BitWriter.data()` — drop the intermediate array

**Question.** `data()` does `words.map { $0.bigEndian }` (a full second
`[UInt64]` allocation) and then copies into `Data` — two allocations and two
O(n) passes. Can one allocation do it?

- **Current:** `map` to a byte-swapped array, then `Data(bytes:)`.
- **Alternative:** allocate the `Data` once and write each word's `.bigEndian`
  straight into it.

## What was tested

Both in one module under `-O`; output asserted byte-identical
(`data() == dataAlt()`) on a 512 KiB payload. Timing: 3000 conversions per
measurement, best-of-3, 5 interleaved repeats.

## Results (median, 3000× 512 KiB)

| | time | per call |
| --- | --- | --- |
| current (`map` + copy) | ~111.5 ms | ~0.037 ms |
| alternative (single buffer) | ~36.1 ms | ~0.012 ms |

## Calculation / interpretation

Speedup = 111.5 / 36.1 ≈ **3.1×**. The win is from removing the intermediate
`[UInt64]` allocation and one of the two O(n) passes; the remaining cost is the
single unavoidable byte-swap-and-store pass.

## Decision

**Adopted.** Shipped with **alignment-safe** per-word `memcpy` stores (instead
of `storeBytes`, which can trap on tiny inline-stored `Data` that isn't
8-aligned). The 3× comes from the single-allocation structure, not the store
instruction, so the portable variant keeps the win — re-verified on the
committed code at **~3.3×** (≈108 → ≈32.8 ms). No API change; all tests pass.

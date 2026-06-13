# Cursor representation — split vs single counter

**Question.** The reader/writer tracked position as a denormalized pair
(`wordIndex`, `bitIndex`) to avoid recomputing `>> 6` / `& 63` each call. Is
storing two fields actually faster than storing one and recomputing?

- **Variant A (split):** stores `wordIndex` + `bitIndex`.
- **Variant B (single):** stores one counter (`bitCount` for the writer,
  `position` for the reader); derives word/offset locally.

## What was tested

Both full implementations compiled in one module under `-O`. A behavioural
fingerprint (hash of all decoded values + produced bytes) confirmed the variants
are identical (`e0e8cce75df11994`). Stress: 163 M write ops & 327 M read ops per
measurement, best-of-3, 8 interleaved repeats.

## Results (median)

| Operation | split (A) | single (B) | winner |
| --- | --- | --- | --- |
| write | ~560 ms · 290 M/s | ~495 ms · 330 M/s | **single +14%** |
| read | ~800 ms · 408 M/s | ~697 ms · 474 M/s | **single +16%** |

Single won **all 8** interleaved pairs on both read and write, with no overlap.

## Calculation / interpretation

Speedup = split_time / single_time → 560/495 ≈ 1.13, 800/697 ≈ 1.15. The
"optimization" of storing two fields was a **pessimization**: keeping two
fields in sync costs extra branches and memory writes, while `>> 6` / `& 63` are
~1-cycle ALU ops that overlap with the array load. The single counter also
collapses the per-call advance to one unconditional `+= bits` (fewer branches).

## Decision

**Adopted the single-counter design.** Writer stores `words` + `bitCount`;
reader stores `words` + `bitCount` + `position`. `bitIndex`/`wordIndex` are now
locals. Faster, smaller structs, simpler advance logic — and it removed the
confusing `bitIndex` vs `bitCount` naming. Public API unchanged; all tests pass.

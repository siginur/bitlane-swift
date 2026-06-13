# `BitReader(Data)` — byte- vs word-at-a-time construction

**Question.** Construction packs the input into `[UInt64]` one **byte** at a
time (8 shifts/ORs per word). Is loading whole words faster?

- **Current:** per-byte loop, `words[i>>3] |= UInt64(byte) << shift`.
- **Alternative:** `memcpy` the bytes into the word buffer, then byte-swap each
  word with `.bigEndian` (8 bytes per iteration instead of 1).

## What was tested

Both `init`s in one module under `-O`. Equivalence asserted at runtime
(`r.words == rAlt.words && bitCount` equal) on a 512 KiB blob. Timing: 1000
constructions per measurement, best-of-3, 5 interleaved repeats.

## Results (median, 1000× 512 KiB)

| | time | per construct | throughput |
| --- | --- | --- | --- |
| current (byte-at-a-time) | ~607.7 ms | ~0.61 ms | ~0.84 GB/s |
| alternative (word-at-a-time) | ~17.6 ms | ~0.018 ms | ~29 GB/s |

## Calculation / interpretation

Speedup = 607.7 / 17.6 ≈ **34.6×**. The per-byte loop does 8× the iterations and
serializes a dependent `|=` chain; `memcpy` + one `REV` (byte-swap) per word is
vectorizable and memory-bandwidth bound. This step previously *dominated* read
timing whenever a reader was constructed inside the measured loop.

## Decision

**Adopted.** Pure internal change, no API impact, fully portable
(`copyMemory` + `.bigEndian`, no availability gates). Biggest single win found;
especially relevant to per-message/packet decoders that build many readers.
Re-verified on the committed code: **~33×** (≈545 → ≈16.7 ms). All tests pass.

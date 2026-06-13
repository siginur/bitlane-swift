# Bulk byte I/O — per-byte loop vs bulk append

**Question.** Packing a byte blob today means `for b in bytes { write(b, bits: 8) }`.
When the writer is byte/word-aligned, that whole loop could be a near-`memcpy`.
How much is on the table?

- **Baseline:** per-byte `write(_:bits:8)` loop.
- **Alternative:** `writeBytesAligned` — append 8 bytes per word directly
  (measured on a word-aligned writer, the best case).

## What was tested

Both in one module under `-O`; output asserted byte-identical (`data()` equal)
on a 512 KiB blob. Timing: 2000 encodes per measurement, best-of-3, 5
interleaved repeats.

## Results (median, 2000× 512 KiB)

| | time | throughput |
| --- | --- | --- |
| per-byte loop | ~926.3 ms | ~1.1 GB/s |
| bulk append | ~112.4 ms | ~9.1 GB/s |

## Calculation / interpretation

Speedup = 926.3 / 112.4 ≈ **8.2×**. Per-byte writes pay the full call core 8×
per word; bulk append moves whole words and is memory-bandwidth bound. This is
the **word-aligned ceiling**; a real bulk path must also handle byte-aligned and
unaligned cursors (with shifting), so practical gains depend on alignment —
though byte blobs in real formats are usually byte-aligned.

## Decision

**Adopted** as `BitWriter.write(contentsOf:)` (`Data` and `[UInt8]`) and
`BitReader.readData(_:)` / `readBytes(_:)` (returning `Data` / `[UInt8]`, sharing
one raw-buffer fill core). The shipped implementation: (1) handles arbitrary
cursor alignment via a head/body/tail split (byte-aligned bytes until
word-aligned, bulk whole words, then trailing bytes), falling back to the
per-byte path only when bit-unaligned; (2) uses a portable `memcpy`-based load
(no `loadUnaligned`), preserving older-OS support. Re-verified on the committed
code: `write(contentsOf:)` from a word-aligned start runs **~13×** the per-byte
loop (≈2750 → ≈211 ms over 2000× 512 KiB). Covered by new alignment tests.

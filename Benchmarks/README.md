# BitLane Benchmarks

Performance experiments that informed BitLane's design. Each file summarises
**what was measured, the numbers, and the decision** — not the benchmark code.

| Benchmark | Question | Outcome |
| --- | --- | --- |
| [inlinable.md](inlinable.md) | Does `@inlinable` speed up the API? | No (for SPM source) → **removed** |
| [cursor-representation.md](cursor-representation.md) | Split cursor vs single counter? | Single is faster → **adopted** |
| [reader-construction.md](reader-construction.md) | Byte- vs word-at-a-time `BitReader(Data)` | **34× faster** → **adopted** |
| [data-serialization.md](data-serialization.md) | Remove the intermediate array in `data()` | **3× faster** → **adopted** |
| [single-bit-ops.md](single-bit-ops.md) | Specialised `write(Bool)` / `readBit()` | **3–7× faster** → **adopted** |
| [bulk-byte-io.md](bulk-byte-io.md) | Bulk byte append vs per-byte loop | **8× faster** → **adopted** (new API) |
| [precondition-vs-throws.md](precondition-vs-throws.md) | Make misuse checks throw instead of trap? | ~6–8% slower write, but catchable → **moved to throws** |

## How everything was tested

- **Methodology.** Each candidate is compiled **in the same module as the real
  library, built with `-O`** — this mirrors how an SPM consumer builds BitLane
  from source (the optimizer sees everything). The current and alternative
  implementations live side by side so they run in one process.
- **Correctness first.** Before any timing, the two implementations are asserted
  to produce **identical output** (same bytes / decoded values / fingerprint).
  No timing is trusted unless equivalence holds.
- **Timing.** Wall-clock via `DispatchTime`, **best-of-3** trials per
  measurement (least-noisy estimator), **5–8 interleaved repeats**, **median**
  reported. Work is folded into a printed checksum to prevent dead-code
  elimination.
- **Environment.** Apple Silicon (`arm64`), macOS, Apple Swift 6.2.x, release.
  Absolute milliseconds are machine-specific; the **ratios** are the takeaway.

To reproduce, recreate the side-by-side variants and run interleaved; the
scaffolding is intentionally not committed.

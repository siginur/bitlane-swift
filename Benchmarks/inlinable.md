# `@inlinable` — is it worth it?

**Question.** The library was annotated with `@inlinable` / `@usableFromInline`.
Does it actually make the hot path faster?

## What was tested

`@inlinable` only matters when the caller is compiled against a **prebuilt
module** with no source (binary distribution). So the benchmark used two
independent `swiftc` invocations — build BitLane to a `.swiftmodule`, then build
a caller against only that module — for three library variants: without the
attribute, with it, and with `@inlinable` + `@inline(__always)`. Assembly call
sites were inspected to confirm what actually inlined.

## Results (best-of-7, separate compilation)

| Variant | hot path | write | read |
| --- | --- | --- | --- |
| without `@inlinable` | not inlined | ~27.5 ms | ~38.1 ms |
| `@inlinable` (as shipped) | **still not inlined** | ~29.4 ms | ~37.8 ms |
| `@inlinable` + `@inline(__always)` | inlined | **~12.1 ms** | **~28.9 ms** |

## Calculation / interpretation

- `@inlinable` alone = **no measurable change**. The compiler is *allowed* to
  inline the body cross-module but **declines** (the methods exceed its cost
  threshold), so calls remain — confirmed in the assembly.
- Only `@inline(__always)` forces it, yielding ~2.3× write / ~1.3× read — the
  win comes from hoisting the array's bounds/CoW checks out of the caller loop.
- Within one SPM build (the common case) cross-module optimization inlines
  everything regardless, so none of it applies to source consumers.

## Decision

**Removed `@inlinable` / `@usableFromInline`.** The library is distributed
open-source via SPM (consumers build from source), where the attribute is inert.
Dropping it simplifies the API surface with zero performance cost. `@inline(__always)`
was rejected: it only helps binary distribution and would freeze the ABI.

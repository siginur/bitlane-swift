# Misuse checks — `precondition` vs `guard` + `throw`

**Question.** Width/count misuse checks trap via `precondition`. Since it isn't
stripped in `-O`, the check costs the same as a `guard` — so is converting them
to `throw` free? The check is; the question is whether marking the **non-throwing**
hot path `write(_:bits:)` as `throws` (reserved error register + post-call check)
is too.

## What was tested

Both `write` variants in one module under `-O -wmo`, outputs asserted identical
first. 5 M writes/trial over a mixed width set (in-word + boundary-spanning),
best-of-3, median of 15. Two call modes: **default inlining** (source consumer)
and **`@inline(never)`** (module boundary).

## Results (median, 5 M writes/trial)

| Call mode | precondition | throws | ratio |
| --- | --- | --- | --- |
| default inlining | ~15.2 ms | ~16.4 ms | **1.06–1.08** |
| `@inline(never)` | ~15.7 ms | ~16.4 ms | 1.00–1.05 |

## Calculation / interpretation

~7% slower for source consumers, stable across runs. Inlining does **not** erase
it: the caller's `do/try/catch` keeps a throw path the optimizer can't prove dead
(it depends on the runtime `bits`). The check was free; *being a throwing
function* was not.

## Decision

**Moved every fallible read/write operation to `throws`.** The ~7% is a real
cost, but a bit stream often decodes untrusted input (files, network), where an
out-of-range width, position, or count can come from the data — and trapping
there means an unrecoverable crash in production. Making these catchable
(`BitLaneError`) lets callers handle bad input gracefully, which outweighs the
margin. Operations that cannot fail (`write(_ bit:)`, `write(contentsOf:)`,
`data()`) stay non-throwing.

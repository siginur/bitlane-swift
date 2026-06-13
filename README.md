# BitLane

[![Swift 5.5+](https://img.shields.io/badge/Swift-5.5%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20Linux-blue.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**BitLane** is an extremely fast, lightweight bit stream library for Swift,
built for compact binary serialization and deserialization. It gives you
precise, bit-level control over an in-memory buffer while keeping allocations
and overhead to a minimum.

## Overview

Most binary formats waste space because the smallest unit you can naturally read
or write is a byte. BitLane lets you pack values at *bit* granularity — a 3-bit
tag, a 12-bit length, a 1-bit flag — directly next to each other with no padding
between fields. It is ideal for serialization, networking, file formats,
compression, and custom protocols.

All work happens in memory: a `BitWriter` accumulates bits and hands you a
`Data` on demand, while a `BitReader` loads a `Data` once and reads it with
random access. There is no incremental or I/O-backed streaming today.

The API is intentionally tiny: two types, `BitWriter` and `BitReader`, and a
handful of methods. There are no protocols to conform to and no configuration
knobs.

## Capabilities

| Area | What BitLane provides |
| --- | --- |
| **Bit-level access** | Read and write fields of any width from 0 to 64 bits, packed with no padding between them. Fields transparently span machine-word boundaries. |
| **Byte payloads** | `write(contentsOf:)`, `readData(_:)`, and `readBytes(_:)` move whole byte blobs of any size, at any bit offset, a machine word at a time. |
| **Bit ordering** | MSB-first: the first bit written is the most-significant bit of the first byte, matching how protocols and specifications describe bit fields. |
| **Cursor control** | `peek` inspects upcoming bits without consuming them; `bitPosition`, `seek`, `skip`, `alignToByte`, and `reset` move the cursor freely to backtrack or realign. |
| **Storage model** | Backed by `[UInt64]` and operating on whole 64-bit words, never bit-by-bit or `[Bool]`. Converts to `Data` only on demand. |
| **Error handling** | Short reads, out-of-range widths, and invalid positions throw `BitLaneError` rather than trapping, so callers can recover. |
| **Portability** | Pure Swift with no dependencies; runs on Apple platforms and Linux. |

## Installation

Add BitLane to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/siginur/bitlane-swift.git", from: "1.0.0")
]
```

Then add it to your target's dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: ["BitLane"]
)
```

In Xcode, use **File → Add Package Dependencies…** and paste the repository URL.

## Quick Start

### Writing

```swift
import BitLane

var writer = BitWriter()
try writer.write(0b101, bits: 3)   // buffer: 101
try writer.write(0b11,  bits: 2)   // buffer: 10111
let data = writer.data()           // [0b1011_1000]
```

### Reading

```swift
import BitLane

var reader = BitReader(data)
let value = try reader.read(bits: 5)   // 0b10111
```

You can also read fields individually, in the same order they were written:

```swift
var reader = BitReader(data)
let tag    = try reader.read(bits: 3)  // 0b101
let flags  = try reader.read(bits: 2)  // 0b11
```

To avoid a round trip through `Data`, build a reader straight from a writer:

```swift
var reader = BitReader(writer)
```

### Peeking and seeking

Look at upcoming bits without consuming them, then move the cursor freely.
`peek` is non-mutating, so it even works on a `let` reader; `position` can be
captured and restored to backtrack:

```swift
var reader = BitReader(data)

if try reader.peek(bits: 4) == marker {  // inspect without advancing
    _ = try reader.read(bits: 4)         // commit only if it matches
}

let mark = reader.bitPosition               // remember where we are
let tag = try reader.read(bits: 3)
if tag != expected { try reader.seek(toBit: mark) }   // ...and rewind

try reader.skip(bits: 8)    // jump forward (negative rewinds)
try reader.alignToByte()    // discard padding up to the next whole byte
reader.reset()              // back to the start
```

### Bulk bytes

Mix bit fields with whole byte payloads. When the writer is byte-aligned, the
payload is copied a word at a time instead of byte by byte:

```swift
let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])

var writer = BitWriter()
try writer.write(0xF, bits: 4)        // a 4-bit tag
try writer.write(contentsOf: payload) // append a Data or [UInt8] blob

var reader = BitReader(writer)
let tag  = try reader.read(bits: 4)
let blob = try reader.readData(payload.count)    // Data; readBytes(_:) gives [UInt8]
```

`BitWriter.alignToByte()` pads with zero bits to the next byte boundary (the
mirror of the reader's), so writing it before a payload both keeps the layout
byte-aligned and takes the fast word-at-a-time copy path.

### Values wider than 64 bits

`read(bits:)` and `write(_:bits:)` handle fields up to 64 bits. For larger
values — a 128-bit ID, a 256-bit hash — use the byte API: `write(contentsOf:)`
and `readData(_:)` / `readBytes(_:)` move payloads of any size, at any bit offset.

## Performance

BitLane is built around a few deliberate choices:

- **`[UInt64]` storage** — bits accumulate in 64-bit machine words, never
  `[Bool]` or `Data`, so every operation works on whole words.
- **MSB-first packing** — the first bit written is the most-significant bit of
  the first byte, matching how protocols and humans describe bit fields.
- **Low allocation** — the writer grows one word at a time and never repacks; the
  reader loads its input once and allocates nothing while reading bit fields. Call
  `reserveCapacity(bits:)` when the size is known to avoid reallocation.

`write(_:bits:)` and `read(bits:)` are O(1); byte payloads and `data()` are O(n).

## Benchmarks

The design choices above were not guesses. The [`Benchmarks/`](Benchmarks/)
directory documents the performance experiments behind them — each file records
what was measured, the resulting numbers, and the decision they led to (for
example, word-at-a-time `BitReader(Data)` construction measured 34× faster than
the byte-at-a-time version, and was adopted). See
[`Benchmarks/README.md`](Benchmarks/README.md) for the full index and the
testing methodology.

## Requirements

- Swift 5.5+
- macOS 10.15+, iOS 13+, tvOS 13+, watchOS 6+, or Linux

## License

BitLane is available under the [MIT License](LICENSE).

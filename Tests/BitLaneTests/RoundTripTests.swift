import XCTest
import Foundation
@testable import BitLane

/// End-to-end coverage: bits and bytes written by ``BitWriter`` must read back
/// identically through ``BitReader``, both directly and via the packed `Data`.
final class RoundTripTests: XCTestCase {

    // MARK: - Bit-field round trips

    func testRoundTripWidthsAtBoundaries() throws {
        try assertRoundTrip([
            (0, 0),
            (1, 1),
            (0, 1),
            (0x7FFF_FFFF_FFFF_FFFF, 63),
            (UInt64.max, 64),
            (0b101, 3),
            (0b11, 2),
        ])
    }

    func testRoundTripEverySingleWidth() throws {
        // For each width 1...64, write a value and read it back.
        var fields: [(UInt64, Int)] = []
        for bits in 1...64 {
            let mask = bits == 64 ? UInt64.max : (UInt64(1) << bits) - 1
            fields.append((0xA5A5_A5A5_A5A5_A5A5 & mask, bits))
        }
        try assertRoundTrip(fields)
    }

    func testRoundTripFillsWordExactly() throws {
        // 64 single-bit writes fill exactly one word.
        var fields: [(UInt64, Int)] = []
        for i in 0..<64 {
            fields.append((UInt64(i & 1), 1))
        }
        try assertRoundTrip(fields)
    }

    func testRoundTripStraddlesManyWords() throws {
        // 13-bit fields do not divide 64, so fields land at every offset.
        var fields: [(UInt64, Int)] = []
        for i in 0..<100 {
            fields.append((UInt64(i) & 0x1FFF, 13))
        }
        try assertRoundTrip(fields)
    }

    // MARK: - Alignment round trip

    /// Padding written by `BitWriter.alignToByte()` is exactly what
    /// `BitReader.alignToByte()` skips, so a field-pad-byte layout round-trips.
    func testWriterAndReaderAlignmentAreSymmetric() throws {
        var writer = BitWriter()
        try writer.write(0b110 as UInt64, bits: 3)
        try writer.alignToByte()             // emit padding
        try writer.write(contentsOf: [0xDE, 0xAD])

        var reader = BitReader(writer)
        XCTAssertEqual(try reader.read(bits: 3), 0b110)
        XCTAssertEqual(try reader.alignToByte(), 5) // discard the same padding
        XCTAssertEqual(try reader.readBytes(2), [0xDE, 0xAD])
        XCTAssertTrue(reader.isAtEnd)
    }

    // MARK: - Bulk byte round trips

    /// `write(contentsOf:)` must produce exactly the same buffer as a per-byte
    /// loop, for both `Data` and `[UInt8]`, at every prefix alignment
    /// (word-aligned, byte-aligned, and bit-unaligned).
    func testBulkWriteMatchesPerByte() throws {
        let sizes = [0, 1, 7, 8, 9, 63, 64, 65, 100, 1000, 4097]
        let prefixes = [0, 1, 3, 7, 8, 13, 16, 24, 56, 63, 64]
        for n in sizes {
            let bytes = blob(n)
            for p in prefixes {
                let reference = try perByte(prefixBits: p, bytes)

                var wData = BitWriter()
                if p > 0 { try wData.write(0xA5A5_A5A5_A5A5_A5A5 as UInt64, bits: p) }
                try wData.write(contentsOf: Data(bytes))
                XCTAssertEqual(wData.data(), reference, "Data overload n=\(n) prefix=\(p)")

                var wArr = BitWriter()
                if p > 0 { try wArr.write(0xA5A5_A5A5_A5A5_A5A5 as UInt64, bits: p) }
                try wArr.write(contentsOf: bytes)
                XCTAssertEqual(wArr.data(), reference, "[UInt8] overload n=\(n) prefix=\(p)")

                XCTAssertEqual(wData.bitCount, p + n * 8)
            }
        }
    }

    /// `readBytes`/`readData` must return exactly the bytes written, after a
    /// prefix field of any width, including the bit-unaligned fallback.
    func testReadBytesRoundTrip() throws {
        let sizes = [0, 1, 7, 8, 9, 64, 65, 100, 1000, 4097]
        let prefixes = [0, 1, 3, 7, 8, 13, 16, 24, 64]
        for n in sizes {
            let bytes = blob(n, seed: 0xCAFEBABEDEADBEEF)
            for p in prefixes {
                var w = BitWriter()
                let prefixValue: UInt64 = 0x1234_5678_9ABC_DEF0
                if p > 0 { try w.write(prefixValue, bits: p) }
                try w.write(contentsOf: bytes)

                let mask = p == 64 ? UInt64.max : (UInt64(1) << p) - 1

                var r = BitReader(w)
                if p > 0 { XCTAssertEqual(try r.read(bits: p), prefixValue & mask, "prefix n=\(n) p=\(p)") }
                XCTAssertEqual(try r.readBytes(n), bytes, "readBytes n=\(n) prefix=\(p)")
                XCTAssertEqual(r.bitsRemaining, 0)

                var r2 = BitReader(w)
                if p > 0 { _ = try r2.read(bits: p) }
                XCTAssertEqual(try r2.readData(n), Data(bytes), "readData n=\(n) prefix=\(p)")
                XCTAssertEqual(r2.bitsRemaining, 0)
            }
        }
    }

    /// Reading a byte payload then continuing to read bit fields stays aligned.
    func testInterleavedFieldsAndBytes() throws {
        let payload = blob(300, seed: 0x0F0F0F0F0F0F0F0F)
        var w = BitWriter()
        try w.write(0b101, bits: 3)
        try w.write(contentsOf: payload)
        try w.write(0xABCD, bits: 16)

        var r = BitReader(w)
        XCTAssertEqual(try r.read(bits: 3), 0b101)
        XCTAssertEqual(try r.readBytes(payload.count), payload)
        XCTAssertEqual(try r.read(bits: 16), 0xABCD)
        XCTAssertTrue(r.isAtEnd)
    }

    /// A large payload exercises the head/body/tail split of the byte fast path.
    func testLargeByteAlignedPayload() throws {
        let bytes = blob(50_000, seed: 0x1122334455667788)
        var w = BitWriter()
        try w.write(0xA5A5_A5A5_A5A5_A5A5 as UInt64, bits: 8)   // byte-aligned, not word-aligned
        try w.write(contentsOf: bytes)
        XCTAssertEqual(w.data(), try perByte(prefixBits: 8, bytes))

        var r = BitReader(w)
        XCTAssertEqual(try r.read(bits: 8), 0xA5)
        XCTAssertEqual(try r.readBytes(bytes.count), bytes)
    }

    // MARK: - Stress

    func testLargeRandomizedFieldRoundTrip() throws {
        var rng = SplitMix64(seed: 0xDEAD_BEEF_CAFE_F00D)

        let fieldCount = 50_000
        var values = [UInt64](repeating: 0, count: fieldCount)
        var widths = [Int](repeating: 0, count: fieldCount)

        var writer = try BitWriter(reservingBitCapacity: fieldCount * 32)
        for i in 0..<fieldCount {
            let bits = Int(rng.next() % 65) // 0...64
            let mask = bits == 64 ? UInt64.max : (UInt64(1) << bits) - 1
            let value = bits == 0 ? 0 : rng.next() & mask
            values[i] = value
            widths[i] = bits
            try writer.write(value, bits: bits)
        }

        var reader = BitReader(writer)
        for i in 0..<fieldCount {
            XCTAssertEqual(try reader.read(bits: widths[i]), values[i], "mismatch at field \(i)")
        }
        XCTAssertTrue(reader.isAtEnd)
    }

    func testLargeRandomizedDataRoundTrip() throws {
        var rng = SplitMix64(seed: 0x1234_5678_9ABC_DEF0)
        var writer = BitWriter()
        var values: [(UInt64, Int)] = []
        for _ in 0..<10_000 {
            let bits = Int(rng.next() % 64) + 1 // 1...64
            let mask = bits == 64 ? UInt64.max : (UInt64(1) << bits) - 1
            let value = rng.next() & mask
            values.append((value, bits))
            try writer.write(value, bits: bits)
        }

        // Re-reading from the produced Data must yield the same fields.
        var reader = BitReader(writer.data())
        for (value, bits) in values {
            XCTAssertEqual(try reader.read(bits: bits), value)
        }
    }
}

// MARK: - Helpers

extension RoundTripTests {

    /// Writes a sequence of (value, width) fields, then reads them back through
    /// both the direct writer→reader path and the path through `Data`.
    private func assertRoundTrip(
        _ fields: [(value: UInt64, bits: Int)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var writer = BitWriter()
        for field in fields {
            try writer.write(field.value, bits: field.bits)
        }

        func verify(_ reader: inout BitReader) throws {
            for field in fields {
                let mask = field.bits == 64 ? UInt64.max : (UInt64(1) << field.bits) - 1
                let expected = field.bits == 0 ? 0 : field.value & mask
                XCTAssertEqual(try reader.read(bits: field.bits), expected, file: file, line: line)
            }
            // Only padding (fewer than 8 bits) may remain.
            XCTAssertLessThan(reader.bitsRemaining, 8, file: file, line: line)
        }

        // Reading straight from the writer has an exact bit count.
        var directReader = BitReader(writer)
        try verify(&directReader)
        XCTAssertTrue(directReader.isAtEnd, file: file, line: line)

        // Reading from Data may carry up to 7 bits of zero padding.
        var dataReader = BitReader(writer.data())
        try verify(&dataReader)
    }

    /// A deterministic pseudo-random byte blob.
    private func blob(_ n: Int, seed: UInt64 = 0x243F6A8885A308D3) -> [UInt8] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: s >> 33)
        }
    }

    /// Reference encoding: append `bytes` to a writer one byte at a time.
    private func perByte(prefixBits: Int, _ bytes: [UInt8]) throws -> Data {
        var w = BitWriter()
        if prefixBits > 0 { try w.write(0xA5A5_A5A5_A5A5_A5A5 as UInt64, bits: prefixBits) }
        for b in bytes { try w.write(b, bits: 8) }
        return w.data()
    }
}

/// A tiny, fast, deterministic pseudo-random generator used only by the tests.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

import XCTest
@testable import BitLane

final class BitWriterTests: XCTestCase {

    // MARK: - Construction & capacity

    func testEmptyWriterProducesEmptyData() {
        let writer = BitWriter()
        XCTAssertTrue(writer.isEmpty)
        XCTAssertEqual(writer.bitCount, 0)
        XCTAssertEqual(writer.byteCount, 0)
        XCTAssertEqual(writer.data(), Data())
    }

    func testReserveCapacityDoesNotChangeContent() throws {
        var writer = try BitWriter(reservingBitCapacity: 1024)
        try writer.write(0b101 as UInt64, bits: 3)
        try writer.reserveCapacity(bits: 4096)
        try writer.write(0b11 as UInt64, bits: 2)
        XCTAssertEqual(writer.data(), Data([0b1011_1000]))
    }

    func testReservingZeroCapacityIsValid() throws {
        var writer = try BitWriter(reservingBitCapacity: 0)
        XCTAssertTrue(writer.isEmpty)
        try writer.reserveCapacity(bits: 0)
        try writer.write(0b1 as UInt64, bits: 1)
        XCTAssertEqual(writer.data(), Data([0b1000_0000]))
    }

    // MARK: - Writing bit fields

    func testMultiBitWriteMatchesSpecExample() throws {
        var writer = BitWriter()
        try writer.write(0b101 as UInt64, bits: 3)
        try writer.write(0b11 as UInt64, bits: 2)
        XCTAssertEqual(writer.bitCount, 5)
        // 10111 padded -> 0b1011_1000.
        XCTAssertEqual(writer.data(), Data([0b1011_1000]))
    }

    func testWriteOnlyKeepsLowBits() throws {
        var writer = BitWriter()
        // Upper bits beyond the requested width must be discarded.
        try writer.write(0b1111_1101 as UInt64, bits: 3) // keeps 101
        XCTAssertEqual(writer.data(), Data([0b1010_0000]))
    }

    func testWidthOneKeepsOnlyTheLowestBit() throws {
        var writer = BitWriter()
        try writer.write(0xFE as UInt64, bits: 1) // lowest bit is 0
        try writer.write(0xFF as UInt64, bits: 1) // lowest bit is 1
        XCTAssertEqual(writer.bitString, "01")
    }

    func testExactByteWrite() throws {
        var writer = BitWriter()
        try writer.write(0xAB as UInt8, bits: 8)
        XCTAssertEqual(writer.bitCount, 8)
        XCTAssertEqual(writer.data(), Data([0xAB]))
    }

    func testExact64BitWrite() throws {
        var writer = BitWriter()
        let value: UInt64 = 0x0123_4567_89AB_CDEF
        try writer.write(value, bits: 64)
        XCTAssertEqual(writer.bitCount, 64)
        XCTAssertEqual(writer.data(), Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]))
    }

    func testZeroBitWriteIsNoOp() throws {
        var writer = BitWriter()
        try writer.write(0xFF as UInt64, bits: 0)
        XCTAssertEqual(writer.bitCount, 0)
        XCTAssertTrue(writer.isEmpty)
    }

    // MARK: - Writing single bits

    func testSingleBitWrite() {
        var writer = BitWriter()
        writer.write(true)
        XCTAssertEqual(writer.bitCount, 1)
        XCTAssertEqual(writer.byteCount, 1)
        // A single 1 packed MSB-first -> 0b1000_0000.
        XCTAssertEqual(writer.data(), Data([0b1000_0000]))
    }

    func testSingleBitsAssembleIntoKnownPattern() {
        var writer = BitWriter()
        for bit in [true, false, true, false, true, false, true, false] {
            writer.write(bit)
        }
        XCTAssertEqual(writer.bitString, "10101010")
        XCTAssertEqual(writer.data(), Data([0xAA]))
    }

    // MARK: - Typed & signed writes

    func testTypedOverloads() throws {
        var writer = BitWriter()
        try writer.write(0x1 as UInt8, bits: 4)
        try writer.write(0x2 as UInt16, bits: 4)
        try writer.write(0x3 as UInt32, bits: 4)
        try writer.write(0x4 as UInt64, bits: 4)
        XCTAssertEqual(writer.data(), Data([0x12, 0x34]))
    }

    func testSignedSubWidthWritesTwosComplementLowBits() throws {
        var writer = BitWriter()
        // -1 as Int8 is 0b1111_1111; the low 4 bits are 0b1111.
        try writer.write(Int8(-1), bits: 4)
        // -2 as Int8 is 0b1111_1110; the low 4 bits are 0b1110.
        try writer.write(Int8(-2), bits: 4)
        XCTAssertEqual(writer.data(), Data([0b1111_1110]))
    }

    func testSignedFullWidthPreservesTwosComplement() throws {
        var writer = BitWriter()
        try writer.write(Int8(-1), bits: 8)   // 0b1111_1111
        try writer.write(Int16(-2), bits: 16) // 0b1111_1111_1111_1110
        XCTAssertEqual(writer.data(), Data([0xFF, 0xFF, 0xFE]))
    }

    // MARK: - Word boundaries

    func testCrossWordWrite() throws {
        var writer = BitWriter()
        try writer.write(0xFFFF_FFFF_FFFF_FFFF as UInt64, bits: 60) // fill most of word 0
        try writer.write(0b1010 as UInt64, bits: 4)                 // finishes word 0
        try writer.write(0b11 as UInt64, bits: 2)                   // starts word 1
        XCTAssertEqual(writer.bitCount, 66)
        XCTAssertEqual(writer.byteCount, 9)

        // The stored bits, not just the cursor: 60 ones, then 1010, then 11.
        XCTAssertEqual(writer.bitString, String(repeating: "1", count: 60) + "1010" + "11")
    }

    func testFieldStraddlingWordBoundaryStoresEachBitInOrder() throws {
        var writer = BitWriter()
        try writer.write(0, bits: 62)     // leave only the last two bits of word 0 free
        try writer.write(0b1101, bits: 4) // bits land at offsets 62, 63 | 64, 65

        XCTAssertEqual(writer.bitCount, 66)
        XCTAssertEqual(writer.bitString.suffix(4), "1101")

        // Seen as bytes, the field splits across the 64-bit word boundary: word 0's
        // final byte ends in `...11`, word 1's first byte begins `01...`.
        let bytes = writer.data()
        XCTAssertEqual(bytes[7], 0b0000_0011)
        XCTAssertEqual(bytes[8], 0b0100_0000)
    }

    func testExactWordFillThenNextWord() throws {
        // Fill word 0 exactly, then start word 1. Exercises the exact-fill
        // branch where the cursor advances to a fresh word.
        var writer = BitWriter()
        try writer.write(UInt64.max, bits: 64)
        XCTAssertEqual(writer.bitCount, 64)
        XCTAssertEqual(writer.byteCount, 8)
        try writer.write(0b1 as UInt64, bits: 1)
        XCTAssertEqual(writer.bitCount, 65)
        XCTAssertEqual(writer.byteCount, 9)
        XCTAssertEqual(writer.data(), Data(repeating: 0xFF, count: 8) + Data([0b1000_0000]))
    }

    func testMultipleWordWrites() throws {
        var writer = BitWriter()
        for _ in 0..<10 {
            try writer.write(0xFFFF_FFFF_FFFF_FFFF as UInt64, bits: 64)
        }
        XCTAssertEqual(writer.bitCount, 640)
        XCTAssertEqual(writer.byteCount, 80)
        XCTAssertEqual(writer.data(), Data(repeating: 0xFF, count: 80))
    }

    func testBitCountTracksAcrossManyExactWords() throws {
        // Each 32-bit write keeps the cursor mid-word, then pairs land on the
        // word boundary. Verifies the tracked cursor stays consistent.
        var writer = BitWriter()
        for i in 0..<8 {
            try writer.write(UInt64(i), bits: 32)
            XCTAssertEqual(writer.bitCount, (i + 1) * 32)
        }
        XCTAssertEqual(writer.byteCount, 32)
    }

    // MARK: - data() output & padding

    func testTrailingByteIsZeroPadded() throws {
        var writer = BitWriter()
        try writer.write(0b111 as UInt64, bits: 3)
        // Three written 1-bits, then five zero-padding bits to fill the byte.
        XCTAssertEqual(writer.data(), Data([0b1110_0000]))
        XCTAssertEqual(writer.bitString, "111")
    }

    func testByteCountRoundsUpToWholeBytes() throws {
        var writer = BitWriter()
        XCTAssertEqual(writer.byteCount, 0)
        try writer.write(0 as UInt64, bits: 1)
        XCTAssertEqual(writer.byteCount, 1) // 1 bit still needs a byte
        try writer.write(0 as UInt64, bits: 6)
        XCTAssertEqual(writer.byteCount, 1) // 7 bits fit in one byte
        try writer.write(0 as UInt64, bits: 1)
        XCTAssertEqual(writer.byteCount, 1) // exactly 8 bits
        try writer.write(0 as UInt64, bits: 1)
        XCTAssertEqual(writer.byteCount, 2) // 9 bits spill into a second byte
    }

    // MARK: - alignToByte

    func testAlignToBytePadsToTheNextWholeByte() throws {
        var writer = BitWriter()
        try writer.write(0b101 as UInt64, bits: 3)
        XCTAssertEqual(try writer.alignToByte(), 5) // five zero bits complete the byte
        XCTAssertEqual(writer.bitCount, 8)
        XCTAssertEqual(writer.bitString, "10100000")

        try writer.write(0xFF as UInt64, bits: 8)
        XCTAssertEqual(writer.data(), Data([0b1010_0000, 0xFF]))
    }

    func testAlignToByteIsNoOpWhenAlreadyAligned() throws {
        var writer = BitWriter()
        try writer.write(0xAB as UInt8, bits: 8)
        XCTAssertEqual(try writer.alignToByte(), 0)
        XCTAssertEqual(writer.bitCount, 8)
        XCTAssertEqual(writer.data(), Data([0xAB]))
    }

    func testAlignToByteOnEmptyWriterDoesNothing() {
        var writer = BitWriter()
        XCTAssertEqual(try writer.alignToByte(), 0)
        XCTAssertTrue(writer.isEmpty)
    }

    // MARK: - Bulk byte writes

    func testWriteEmptyBytesIsNoOp() throws {
        var writer = BitWriter()
        try writer.write(contentsOf: Data())
        try writer.write(contentsOf: [UInt8]())
        XCTAssertTrue(writer.isEmpty)
    }

    // MARK: - Copy-on-write

    func testCopiesDoNotShareStorage() throws {
        var original = BitWriter()
        try original.write(0b1010 as UInt64, bits: 4)

        var copy = original
        try copy.write(0b1111 as UInt64, bits: 4)

        // Mutating the copy must leave the original's buffer untouched.
        XCTAssertEqual(original.bitString, "1010")
        XCTAssertEqual(copy.bitString, "10101111")
    }
}

import XCTest
@testable import BitLane

final class BitReaderTests: XCTestCase {

    // MARK: - Construction & empty state

    func testEmptyReader() {
        var reader = BitReader(Data())
        XCTAssertEqual(reader.bitCount, 0)
        XCTAssertEqual(reader.bitsRemaining, 0)
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertEqual(try reader.read(bits: 0), 0)
    }

    func testCopyHasIndependentCursor() throws {
        var reader = BitReader(Data([0b1100_0000]))
        let snapshot = reader
        _ = try reader.read(bits: 2)
        XCTAssertEqual(reader.bitsRemaining, 6)
        XCTAssertEqual(snapshot.bitsRemaining, 8)
    }

    func testMultiWordDataInitWithPartialFinalWord() throws {
        // 13 bytes => spans two words; the second word is only partially filled.
        // Exercises the byte-placement loop across the 8-byte word boundary.
        let bytes: [UInt8] = (1...13).map { UInt8($0) }
        var reader = BitReader(Data(bytes))
        XCTAssertEqual(reader.bitCount, 13 * 8)
        for expected in bytes {
            XCTAssertEqual(try reader.read(bits: 8), UInt64(expected))
        }
        XCTAssertTrue(reader.isAtEnd)
    }

    func testWriterReaderHidesPaddingThatDataReaderExposes() throws {
        var writer = BitWriter()
        try writer.write(0b101 as UInt64, bits: 3) // 3 real bits; data() pads to a full byte

        // Built straight from the writer, the reader knows only 3 bits exist.
        var fromWriter = BitReader(writer)
        XCTAssertEqual(fromWriter.bitCount, 3)
        XCTAssertEqual(try fromWriter.read(bits: 3), 0b101)
        XCTAssertTrue(fromWriter.isAtEnd)
        XCTAssertThrowsError(try fromWriter.readBit())

        // Built from the packed Data, the reader sees the full byte, padding and all.
        var fromData = BitReader(writer.data())
        XCTAssertEqual(fromData.bitCount, 8)
        XCTAssertEqual(try fromData.read(bits: 3), 0b101)
        XCTAssertEqual(try fromData.read(bits: 5), 0) // the five zero-padding bits
        XCTAssertTrue(fromData.isAtEnd)
    }

    // MARK: - Reading bit fields

    func testMultiBitReadMatchesSpecExample() throws {
        var reader = BitReader(Data([0b1011_1000]))
        XCTAssertEqual(try reader.read(bits: 5), 0b10111)
    }

    func testSequentialFieldReads() throws {
        var reader = BitReader(Data([0b1011_1000]))
        XCTAssertEqual(try reader.read(bits: 3), 0b101)
        XCTAssertEqual(try reader.read(bits: 2), 0b11)
    }

    func testExact64BitRead() throws {
        let bytes: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
        var reader = BitReader(Data(bytes))
        XCTAssertEqual(try reader.read(bits: 64), 0x0123_4567_89AB_CDEF)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testReadToExactEnd() throws {
        var reader = BitReader(Data([0xFF]))
        XCTAssertEqual(try reader.read(bits: 8), 0xFF)
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertThrowsError(try reader.readBit())
    }

    func testZeroBitReadConsumesNothingEvenAtEnd() throws {
        var reader = BitReader(Data([0xFF]))
        XCTAssertEqual(try reader.read(bits: 0), 0)
        XCTAssertEqual(reader.bitsRemaining, 8) // nothing consumed mid-buffer

        XCTAssertEqual(try reader.read(bits: 8), 0xFF)
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertEqual(try reader.read(bits: 0), 0) // still valid at the end
    }

    func testFailedReadLeavesCursorUntouched() throws {
        var reader = BitReader(Data([0xFF])) // 8 bits
        XCTAssertEqual(try reader.read(bits: 7), 0b111_1111)

        XCTAssertThrowsError(try reader.read(bits: 2)) { error in
            XCTAssertEqual(error as? BitLaneError, .insufficientBits(requested: 2, available: 1))
        }

        // The throwing read must not have consumed the remaining bit.
        XCTAssertEqual(reader.bitsRemaining, 1)
        XCTAssertEqual(try reader.read(bits: 1), 1)
        XCTAssertTrue(reader.isAtEnd)
    }

    // MARK: - Reading single bits

    func testSingleBitRead() throws {
        var reader = BitReader(Data([0b1000_0000]))
        XCTAssertTrue(try reader.readBit())
        XCTAssertFalse(try reader.readBit())
        XCTAssertEqual(reader.bitsRemaining, 6)
    }

    func testReadBitYieldsEveryBitInOrder() throws {
        var reader = BitReader(Data([0b1010_1010]))
        for expected in [true, false, true, false, true, false, true, false] {
            XCTAssertEqual(try reader.readBit(), expected)
        }
        XCTAssertTrue(reader.isAtEnd)
    }

    func testReadBitOnEmptyBufferReportsNothingAvailable() {
        var reader = BitReader(Data())
        XCTAssertThrowsError(try reader.readBit()) { error in
            XCTAssertEqual(error as? BitLaneError, .insufficientBits(requested: 1, available: 0))
        }
    }

    func testEntireBufferReadsBackBitForBit() throws {
        var writer = BitWriter()
        try writer.write(0b101 as UInt64, bits: 3)
        try writer.write(0b1100 as UInt64, bits: 4)
        writer.write(true)

        var reader = BitReader(writer)
        XCTAssertEqual(try reader.remainingBitString(), "101" + "1100" + "1")
        XCTAssertTrue(reader.isAtEnd)
    }

    // MARK: - Typed & signed reads

    func testTypedReadReturnsRequestedType() throws {
        var reader = BitReader(Data([0xAB, 0xCD]))
        let byte = try reader.read(UInt8.self, bits: 8)
        XCTAssertEqual(byte, 0xAB)
        XCTAssertEqual(reader.bitPosition, 8)
    }

    func testTypedReadNarrowsToFieldWidth() throws {
        // A 12-bit field read into a UInt16, then the remaining 4 bits.
        var reader = BitReader(Data([0xAB, 0xCD]))
        XCTAssertEqual(try reader.read(UInt16.self, bits: 12), 0xABC)
        XCTAssertEqual(try reader.read(UInt8.self, bits: 4), 0xD)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testTypedReadFullWidth() throws {
        let bytes: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
        var reader = BitReader(Data(bytes))
        XCTAssertEqual(try reader.read(UInt64.self, bits: 64), 0x0123_4567_89AB_CDEF)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testTypedReadRoundTripsWriterTypedWrite() throws {
        var writer = BitWriter()
        let value: UInt16 = 0x07F3
        try writer.write(value, bits: 11) // low 11 bits: 0b111_1111_0011
        var reader = BitReader(writer)
        XCTAssertEqual(try reader.read(UInt16.self, bits: 11), value & 0x07FF)
    }

    func testTypedReadSignedFullWidthReinterpretsTwosComplement() throws {
        // A full-width 8-bit field of 0xFF reinterprets as -1 in a signed Int8.
        var reader = BitReader(Data([0xFF]))
        XCTAssertEqual(try reader.read(Int8.self, bits: 8), -1)
    }

    func testTypedReadSignedSubWidthIsNotSignExtended() throws {
        // A sub-width 4-bit field keeps its low bits without sign extension:
        // 0b1111 is 15, not -1.
        var reader = BitReader(Data([0b1111_0000]))
        XCTAssertEqual(try reader.read(Int8.self, bits: 4), 15)
    }

    // MARK: - Word boundaries

    func testCrossWordRead() throws {
        var writer = BitWriter()
        try writer.write(0x3F as UInt64, bits: 60)
        try writer.write(0b1010_11 as UInt64, bits: 6) // crosses the 64-bit boundary
        var reader = BitReader(writer)
        XCTAssertEqual(try reader.read(bits: 60), 0x3F)
        XCTAssertEqual(try reader.read(bits: 6), 0b1010_11)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testReadExactlyFillsWordThenContinues() throws {
        // First read consumes a whole word exactly; the next read must come from
        // the following word. Covers the exact-fill branch of `read`.
        var writer = BitWriter()
        try writer.write(0xDEAD_BEEF_0BAD_F00D as UInt64, bits: 64)
        try writer.write(0xAB as UInt64, bits: 8)
        var reader = BitReader(writer)
        XCTAssertEqual(try reader.read(bits: 64), 0xDEAD_BEEF_0BAD_F00D)
        XCTAssertEqual(try reader.read(bits: 8), 0xAB)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testReadBitAcrossWordBoundary() throws {
        // Place a known bit pattern straddling the 64-bit boundary and read it
        // one bit at a time.
        var writer = BitWriter()
        try writer.write(0 as UInt64, bits: 63)
        try writer.write(0b101 as UInt64, bits: 3) // bits 63, 64, 65 = 1, 0, 1
        var reader = BitReader(writer)
        _ = try reader.read(bits: 63)
        XCTAssertTrue(try reader.readBit())   // bit 63
        XCTAssertFalse(try reader.readBit())  // bit 64 (second word)
        XCTAssertTrue(try reader.readBit())   // bit 65
        XCTAssertTrue(reader.isAtEnd)
    }

    func testSixtyFourBitFieldReadsBackAcrossWordBoundary() throws {
        var writer = BitWriter()
        try writer.write(0b1011 as UInt64, bits: 4)   // push the next field off the word boundary
        let payload: UInt64 = 0x0123_4567_89AB_CDEF
        try writer.write(payload, bits: 64)           // straddles words 0 and 1

        var reader = BitReader(writer)
        XCTAssertEqual(try reader.read(bits: 4), 0b1011)
        XCTAssertEqual(try reader.read(bits: 64), payload)
        XCTAssertTrue(reader.isAtEnd)
    }

    // MARK: - Peeking

    func testPeekReturnsNextBitsWithoutConsuming() throws {
        let reader = BitReader(Data([0b1011_0010]))
        XCTAssertEqual(try reader.peek(bits: 4), 0b1011)
        XCTAssertEqual(try reader.peek(bits: 4), 0b1011) // a second look is identical
        XCTAssertEqual(reader.bitPosition, 0)
        XCTAssertEqual(reader.bitsRemaining, 8)
    }

    func testPeekAgreesWithTheFollowingRead() throws {
        var reader = BitReader(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        for width in [3, 7, 13, 9] {
            let peeked = try reader.peek(bits: width)
            let read = try reader.read(bits: width)
            XCTAssertEqual(peeked, read, "peek and read disagree at width \(width)")
        }
    }

    func testPeekWorksOnAnImmutableReader() throws {
        let reader = BitReader(Data([0xAB])) // `let`, never mutated
        XCTAssertEqual(try reader.peek(bits: 8), 0xAB)
        XCTAssertTrue(try reader.peekBit())
    }

    func testPeekAcrossWordBoundaryMatchesRead() throws {
        var writer = BitWriter()
        try writer.write(0 as UInt64, bits: 60)
        let payload: UInt64 = 0b1011_0110
        try writer.write(payload, bits: 8) // straddles the 64-bit word boundary

        var reader = BitReader(writer)
        try reader.skip(bits: 60)
        XCTAssertEqual(try reader.peek(bits: 8), payload)
        XCTAssertEqual(try reader.read(bits: 8), payload)
    }

    func testTypedPeekDoesNotAdvance() throws {
        let reader = BitReader(Data([0xAB]))
        XCTAssertEqual(try reader.peek(UInt8.self, bits: 8), 0xAB)
        XCTAssertEqual(try reader.peek(UInt8.self, bits: 8), 0xAB)
        XCTAssertEqual(reader.bitPosition, 0)
    }

    func testPeekZeroAlwaysSucceedsEvenAtEnd() throws {
        var reader = BitReader(Data([0xFF]))
        _ = try reader.read(bits: 8)
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertEqual(try reader.peek(bits: 0), 0)
    }

    func testPeekBeyondEndThrowsAndLeavesPositionUntouched() throws {
        var reader = BitReader(Data([0xFF]))
        _ = try reader.read(bits: 6)
        XCTAssertThrowsError(try reader.peek(bits: 4)) { error in
            XCTAssertEqual(error as? BitLaneError, .insufficientBits(requested: 4, available: 2))
        }
        XCTAssertEqual(reader.bitPosition, 6)
    }

    func testPeekBitDoesNotConsume() throws {
        var reader = BitReader(Data([0b1000_0000]))
        XCTAssertTrue(try reader.peekBit())
        XCTAssertTrue(try reader.peekBit())
        XCTAssertEqual(reader.bitPosition, 0)
        XCTAssertTrue(try reader.readBit()) // now actually consume it
        XCTAssertEqual(reader.bitPosition, 1)
    }

    func testPeekBitOnEmptyBufferThrows() {
        let reader = BitReader(Data())
        XCTAssertThrowsError(try reader.peekBit()) { error in
            XCTAssertEqual(error as? BitLaneError, .insufficientBits(requested: 1, available: 0))
        }
    }

    /// A peek that fails on a tentative branch must leave the reader exactly
    /// where it was, so the caller can try a different interpretation.
    func testBacktrackingWithPeekLeavesNoTrace() throws {
        var reader = BitReader(Data([0b1100_0000]))
        let before = reader.bitPosition
        if try reader.peek(bits: 2) == 0b10 {
            _ = try reader.read(bits: 2)
        }
        // The pattern was 0b11, so nothing was consumed.
        XCTAssertEqual(reader.bitPosition, before)
        XCTAssertEqual(try reader.read(bits: 2), 0b11)
    }

    // MARK: - Cursor movement (seek / skip / reset / bitPosition)

    func testSeekToMarkRereadsTheSameField() throws {
        var reader = BitReader(Data([0b1010_1100]))
        let mark = reader.bitPosition
        XCTAssertEqual(try reader.read(bits: 4), 0b1010)
        try reader.seek(toBit: mark)
        XCTAssertEqual(try reader.read(bits: 4), 0b1010) // same bits, second time
    }

    func testSeekToArbitraryOffsetReadsFromThere() throws {
        var reader = BitReader(Data([0x0F, 0xF0])) // 0000_1111 1111_0000
        try reader.seek(toBit: 4)
        XCTAssertEqual(try reader.read(bits: 8), 0xFF) // low nibble + high nibble straddle
    }

    func testSeekToEndLeavesReaderAtEnd() throws {
        var reader = BitReader(Data([0xFF, 0xFF]))
        try reader.seek(toBit: reader.bitCount)
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertEqual(reader.bitsRemaining, 0)
    }

    func testSeekBackwardFromEnd() throws {
        var reader = BitReader(Data([0xAB, 0xCD]))
        _ = try reader.read(bits: 16)
        try reader.seek(toBit: 8)
        XCTAssertEqual(try reader.read(bits: 8), 0xCD)
    }

    func testSkipForwardJumpsOverAField() throws {
        var reader = BitReader(Data([0xAB, 0xCD]))
        try reader.skip(bits: 8) // ignore the first byte
        XCTAssertEqual(try reader.read(bits: 8), 0xCD)
    }

    func testNegativeSkipRewinds() throws {
        var reader = BitReader(Data([0b1101_0000]))
        XCTAssertEqual(try reader.read(bits: 4), 0b1101)
        try reader.skip(bits: -4)
        XCTAssertEqual(try reader.read(bits: 4), 0b1101)
    }

    func testSkipToEitherEndIsValid() throws {
        var reader = BitReader(Data([0xFF]))
        try reader.skip(bits: 8)
        XCTAssertTrue(reader.isAtEnd)
        try reader.skip(bits: -8)
        XCTAssertEqual(reader.bitPosition, 0)
    }

    func testResetReturnsToTheStart() throws {
        var reader = BitReader(Data([0x12, 0x34]))
        XCTAssertEqual(try reader.read(bits: 16), 0x1234)
        reader.reset()
        XCTAssertEqual(reader.bitPosition, 0)
        XCTAssertEqual(try reader.read(bits: 16), 0x1234)
    }

    func testPositionTracksEveryKindOfRead() throws {
        var reader = BitReader(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertEqual(reader.bitPosition, 0)
        _ = try reader.read(bits: 5)
        XCTAssertEqual(reader.bitPosition, 5)
        _ = try reader.readBit()
        XCTAssertEqual(reader.bitPosition, 6)
        _ = try reader.readBytes(2)
        XCTAssertEqual(reader.bitPosition, 22) // 6 + 16 bits, read from a non-aligned cursor
    }

    func testPositionEqualsBitCountMinusRemaining() throws {
        var reader = BitReader(Data([0xAA, 0xBB, 0xCC]))
        _ = try reader.read(bits: 11)
        XCTAssertEqual(reader.bitPosition, reader.bitCount - reader.bitsRemaining)
    }

    // MARK: - alignToByte

    func testAlignToByteSkipsPaddingToNextWholeByte() throws {
        var reader = BitReader(Data([0b1010_1111, 0x42]))
        XCTAssertEqual(try reader.read(bits: 3), 0b101)
        XCTAssertEqual(try reader.alignToByte(), 5) // discard the rest of byte 0
        XCTAssertEqual(reader.bitPosition, 8)
        XCTAssertEqual(try reader.read(bits: 8), 0x42)
    }

    func testAlignToByteIsNoOpWhenAlreadyAligned() throws {
        var reader = BitReader(Data([0x42, 0x43]))
        XCTAssertEqual(try reader.read(bits: 8), 0x42)
        XCTAssertEqual(try reader.alignToByte(), 0)
        XCTAssertEqual(reader.bitPosition, 8)
    }

    func testAlignToByteThrowsWhenPaddingRunsPastEnd() throws {
        // Only 11 bits exist, so aligning from bit 11 would need to reach bit 16.
        var writer = BitWriter()
        try writer.write(0b101 as UInt64, bits: 3)
        try writer.write(0xFF as UInt64, bits: 8)
        var reader = BitReader(writer) // bitCount == 11
        try reader.skip(bits: 11)
        XCTAssertThrowsError(try reader.alignToByte()) { error in
            XCTAssertEqual(error as? BitLaneError, .insufficientBits(requested: 5, available: 0))
        }
    }

    // MARK: - Bulk byte reads

    func testReadZeroBytesReturnsEmpty() throws {
        var reader = BitReader(Data([0x12, 0x34]))
        XCTAssertEqual(try reader.readData(0), Data())
        XCTAssertEqual(try reader.readBytes(0), [])
        XCTAssertEqual(reader.bitPosition, 0)
        XCTAssertEqual(try reader.readBytes(2), [0x12, 0x34])
    }

    func testReadBytesInsufficientThrows() {
        var reader = BitReader(Data([0xFF, 0xFF])) // 16 bits
        XCTAssertThrowsError(try reader.readBytes(3)) { error in
            XCTAssertEqual(error as? BitLaneError, .insufficientBits(requested: 24, available: 16))
        }
        XCTAssertThrowsError(try reader.readData(3)) { error in
            XCTAssertEqual(error as? BitLaneError, .insufficientBits(requested: 24, available: 16))
        }
        // Partially consumed: the byte boundary no longer holds a full byte.
        var partial = BitReader(Data([0xFF]))
        XCTAssertEqual(try partial.read(bits: 4), 0xF)
        XCTAssertThrowsError(try partial.readBytes(1))
    }
}

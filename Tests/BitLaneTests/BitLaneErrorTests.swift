import XCTest
@testable import BitLane

final class BitLaneErrorTests: XCTestCase {

    func testEqualErrorsCompareEqual() {
        XCTAssertEqual(
            BitLaneError.insufficientBits(requested: 9, available: 8),
            BitLaneError.insufficientBits(requested: 9, available: 8)
        )
    }

    func testDifferingFieldsCompareUnequal() {
        let base = BitLaneError.insufficientBits(requested: 9, available: 8)
        XCTAssertNotEqual(base, .insufficientBits(requested: 9, available: 7))
        XCTAssertNotEqual(base, .insufficientBits(requested: 8, available: 8))
    }

    func testDescriptions() {
        XCTAssertEqual(
            BitLaneError.insufficientBits(requested: 9, available: 8).description,
            "BitLaneError.insufficientBits: requested 9 bit(s) but only 8 remain"
        )
        XCTAssertEqual(
            BitLaneError.invalidBitWidth(bits: 65, max: 64).description,
            "BitLaneError.invalidBitWidth: bit width 65 is outside 0...64"
        )
        XCTAssertEqual(
            BitLaneError.invalidPosition(position: 20, bitCount: 16).description,
            "BitLaneError.invalidPosition: position 20 is outside 0...16"
        )
        XCTAssertEqual(
            BitLaneError.negativeCount(-3).description,
            "BitLaneError.negativeCount: -3 must be non-negative"
        )
    }

    /// A read out of bits surfaces the counts the caller needs to recover.
    func testInsufficientBitsReportsActualCounts() {
        var reader = BitReader(Data([0xFF])) // 8 bits available
        XCTAssertThrowsError(try reader.read(bits: 12)) { error in
            XCTAssertEqual(error as? BitLaneError, .insufficientBits(requested: 12, available: 8))
        }
    }

    /// An out-of-range width is now catchable instead of trapping.
    func testInvalidWidthIsThrownNotTrapped() {
        var writer = BitWriter()
        XCTAssertThrowsError(try writer.write(0 as UInt64, bits: 65)) { error in
            XCTAssertEqual(error as? BitLaneError, .invalidBitWidth(bits: 65, max: 64))
        }
        var reader = BitReader(Data([0xFF]))
        XCTAssertThrowsError(try reader.read(bits: -1)) { error in
            XCTAssertEqual(error as? BitLaneError, .invalidBitWidth(bits: -1, max: 64))
        }
        XCTAssertThrowsError(try reader.read(UInt8.self, bits: 9)) { error in
            XCTAssertEqual(error as? BitLaneError, .invalidBitWidth(bits: 9, max: 8))
        }
    }

    /// An out-of-range cursor move is catchable instead of trapping.
    func testInvalidPositionIsThrownNotTrapped() {
        var reader = BitReader(Data([0xFF])) // 8 bits
        XCTAssertThrowsError(try reader.seek(toBit: 9)) { error in
            XCTAssertEqual(error as? BitLaneError, .invalidPosition(position: 9, bitCount: 8))
        }
        XCTAssertThrowsError(try reader.skip(bits: -1)) { error in
            XCTAssertEqual(error as? BitLaneError, .invalidPosition(position: -1, bitCount: 8))
        }
    }

    /// A negative count or capacity is catchable instead of trapping.
    func testNegativeCountIsThrownNotTrapped() {
        var reader = BitReader(Data([0xFF]))
        XCTAssertThrowsError(try reader.readBytes(-1)) { error in
            XCTAssertEqual(error as? BitLaneError, .negativeCount(-1))
        }
        XCTAssertThrowsError(try BitWriter(reservingBitCapacity: -1)) { error in
            XCTAssertEqual(error as? BitLaneError, .negativeCount(-1))
        }
    }
}

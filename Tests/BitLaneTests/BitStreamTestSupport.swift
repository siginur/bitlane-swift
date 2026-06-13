import Foundation
@testable import BitLane

extension BitWriter {

    /// The bits written so far, rendered MSB-first as a run of `'0'`/`'1'`
    /// characters exactly ``bitCount`` long.
    ///
    /// Unlike ``data()``, the trailing zero-padding of the final byte is
    /// excluded, so an assertion sees only the bits the caller actually
    /// appended. This lets tests state the stored layout literally —
    /// `XCTAssertEqual(writer.bitString, "10111")` — instead of reasoning about
    /// padded byte values.
    var bitString: String {
        let bytes = data()
        var rendered = ""
        rendered.reserveCapacity(bitCount)
        for index in 0..<bitCount {
            let bit = (bytes[index >> 3] >> (7 - (index & 7))) & 1
            rendered.append(bit == 1 ? "1" : "0")
        }
        return rendered
    }
}

extension BitReader {

    /// Drains every remaining bit, MSB-first, into a run of `'0'`/`'1'`
    /// characters. Leaves the reader at its end.
    mutating func remainingBitString() throws -> String {
        var rendered = ""
        rendered.reserveCapacity(bitsRemaining)
        while !isAtEnd {
            rendered.append(try readBit() ? "1" : "0")
        }
        return rendered
    }
}

import Foundation

/// A high-performance, MSB-first bit stream reader.
///
/// `BitReader` decodes a bit stream produced by ``BitWriter`` (or any MSB-first
/// packed source) one field at a time. Reads advance a cursor and may span
/// `UInt64` word boundaries transparently:
///
/// ```swift
/// var reader = BitReader(data)
/// let tag   = try reader.read(bits: 3)
/// let value = try reader.read(bits: 12)
/// ```
///
/// Input is loaded once into an array of `UInt64` words, each byte placed
/// most-significant-bit first; subsequent reads allocate nothing. Each
/// ``read(bits:)`` is `O(1)` and inspects at most two words.
///
/// `BitReader` is a value type. A copy keeps its own cursor, making speculative
/// or backtracking reads cheap.
public struct BitReader: Sendable {

    /// The backing storage, packed MSB-first within each word.
    let words: [UInt64]

    /// The total number of readable bits in the buffer.
    ///
    /// Carries the source's exact (possibly sub-byte) bit count: a reader built
    /// from a ``BitWriter`` preserves the writer's count, so two readers with
    /// identical words can expose different lengths.
    public let bitCount: Int

    /// The index of the next bit to read, from the start of the buffer.
    ///
    /// Starts at `0` and advances by every read, reaching ``bitCount`` exactly
    /// when the buffer is consumed. Capture it to mark a spot and return with
    /// ``seek(toBit:)``. The word being read is `bitPosition >> 6` and the
    /// in-word offset is `bitPosition & 63`.
    public private(set) var bitPosition: Int

    /// Creates a reader over the bits in `data`, interpreted MSB first.
    ///
    /// - Parameter data: The packed bit stream to read.
    /// - Complexity: O(n) in the number of bytes.
    public init(_ data: Data) {
        self.bitCount = data.count * 8
        self.bitPosition = 0

        let wordCount = (data.count + 7) >> 3
        guard wordCount > 0 else {
            self.words = []
            return
        }

        // Copy the bytes verbatim into the word buffer, then fix each word's
        // byte order. Trailing bytes of the final word stay zero because the
        // buffer is pre-zeroed.
        var words = [UInt64](repeating: 0, count: wordCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            words.withUnsafeMutableBytes { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: base, count: raw.count))
            }
        }
        for i in 0..<wordCount {
            // `bigEndian` undoes the host byte order so byte 0 lands in the
            // most-significant byte, matching the bitstream's MSB-first ordering.
            words[i] = words[i].bigEndian
        }
        self.words = words
    }

    /// Creates a reader over the bits held by a ``BitWriter``, copying its word
    /// storage directly and preserving its exact bit count.
    ///
    /// - Parameter writer: The writer whose bits should be read.
    /// - Complexity: O(n) in the number of words.
    public init(_ writer: BitWriter) {
        self.words = writer.words
        self.bitCount = writer.bitCount
        self.bitPosition = 0
    }

    /// The number of bits that have not yet been read.
    public var bitsRemaining: Int {
        bitCount - bitPosition
    }

    /// A Boolean value indicating whether every bit has been consumed.
    public var isAtEnd: Bool {
        bitPosition >= bitCount
    }

    /// Reads the next `bits` bits and returns them right-aligned in a `UInt64`.
    ///
    /// The first bit read is the most-significant bit of the result, so it
    /// round-trips with ``BitWriter/write(_:bits:)-(UInt64,_)``.
    ///
    /// - Parameter bits: The number of bits to read, in `0...64`. Reading `0`
    ///   returns `0` and consumes nothing.
    /// - Returns: The bits read, right-aligned.
    /// - Throws: ``BitLaneError/invalidBitWidth(bits:max:)`` if `bits` is outside
    ///   `0...64`; ``BitLaneError/insufficientBits(requested:available:)`` if
    ///   fewer than `bits` bits remain.
    /// - Complexity: O(1).
    public mutating func read(bits: Int) throws -> UInt64 {
        let value = try peek(bits: bits)
        bitPosition += bits
        return value
    }

    /// Reads the next `bits` bits as any fixed-width integer type, advancing the
    /// cursor.
    ///
    /// Narrowing is `truncatingIfNeeded`: a sub-width field is not sign-extended.
    /// A signed `T` is reinterpreted as two's complement across its full
    /// `bitWidth`, so the sign bit only takes effect when `bits == T.bitWidth`.
    ///
    /// - Parameters:
    ///   - type: The integer type to return (e.g. `UInt16.self`).
    ///   - bits: The number of bits to read, in `0...T.bitWidth` and at most `64`.
    /// - Returns: The bits read, right-aligned in `T`.
    /// - Throws: ``BitLaneError/invalidBitWidth(bits:max:)`` if `bits` is out of
    ///   range; ``BitLaneError/insufficientBits(requested:available:)`` if fewer
    ///   than `bits` bits remain.
    /// - Complexity: O(1).
    public mutating func read<T: FixedWidthInteger>(_ type: T.Type, bits: Int) throws -> T {
        let value = try peek(type, bits: bits)
        bitPosition += bits
        return value
    }

    /// Returns the next `bits` bits without advancing the cursor.
    ///
    /// Behaves like ``read(bits:)`` but leaves the position unchanged, so it can
    /// be called on a `let` reader and repeated peeks return the same value.
    ///
    /// - Parameter bits: The number of bits to inspect, in `0...64`.
    /// - Returns: The upcoming bits, right-aligned.
    /// - Throws: ``BitLaneError/invalidBitWidth(bits:max:)`` if `bits` is outside
    ///   `0...64`; ``BitLaneError/insufficientBits(requested:available:)`` if
    ///   fewer than `bits` bits remain.
    /// - Complexity: O(1).
    public func peek(bits: Int) throws -> UInt64 {
        guard bits >= 0 && bits <= 64 else {
            throw BitLaneError.invalidBitWidth(bits: bits, max: 64)
        }
        guard bits > 0 else { return 0 }

        let available = bitCount - bitPosition
        guard bits <= available else {
            throw BitLaneError.insufficientBits(requested: bits, available: available)
        }

        let wordIndex = bitPosition >> 6
        let bitIndex = bitPosition & 63
        let space = 64 - bitIndex
        let mask = (UInt64(1) << bits) &- 1

        if bits <= space {
            // Entirely within the current word, possibly consuming it exactly.
            return (words[wordIndex] >> (space - bits)) & mask
        } else {
            // Spans the boundary. `bitIndex > 0` here, so both shifts stay in
            // 1...63 and are well defined.
            let lowBits = bits - space
            let highPart = words[wordIndex] & ((UInt64(1) << space) &- 1)
            let lowPart = words[wordIndex + 1] >> (64 - lowBits)
            return (highPart << lowBits) | lowPart
        }
    }

    /// Returns the next `bits` bits as any fixed-width integer type without
    /// advancing the cursor.
    ///
    /// - Parameters:
    ///   - type: The integer type to return (e.g. `UInt16.self`).
    ///   - bits: The number of bits to inspect, in `0...T.bitWidth` and at most `64`.
    /// - Returns: The upcoming bits, right-aligned in `T`.
    /// - Throws: ``BitLaneError/invalidBitWidth(bits:max:)`` if `bits` is out of
    ///   range; ``BitLaneError/insufficientBits(requested:available:)`` if fewer
    ///   than `bits` bits remain.
    /// - Complexity: O(1).
    public func peek<T: FixedWidthInteger>(_ type: T.Type, bits: Int) throws -> T {
        guard bits >= 0 && bits <= T.bitWidth else {
            throw BitLaneError.invalidBitWidth(bits: bits, max: T.bitWidth)
        }
        return T(truncatingIfNeeded: try peek(bits: bits))
    }

    /// Reads a single bit.
    ///
    /// - Returns: `true` if the bit is `1`, `false` if it is `0`.
    /// - Throws: ``BitLaneError/insufficientBits(requested:available:)`` if no
    ///   bits remain.
    /// - Complexity: O(1).
    public mutating func readBit() throws -> Bool {
        let bit = try peekBit()
        bitPosition += 1
        return bit
    }

    /// Returns the next bit without advancing the cursor.
    ///
    /// - Returns: `true` if the next bit is `1`, `false` if it is `0`.
    /// - Throws: ``BitLaneError/insufficientBits(requested:available:)`` if no
    ///   bits remain.
    /// - Complexity: O(1).
    public func peekBit() throws -> Bool {
        // A single bit never spans a word boundary and needs no mask.
        guard bitPosition < bitCount else {
            throw BitLaneError.insufficientBits(requested: 1, available: bitCount - bitPosition)
        }
        return (words[bitPosition >> 6] >> (63 - (bitPosition & 63))) & 1 != 0
    }

    // MARK: - Cursor movement

    /// Moves the cursor to an absolute bit offset from the start of the buffer.
    ///
    /// Pair it with ``bitPosition`` to save a location and return to it later.
    ///
    /// - Parameter offset: The new position, in `0...bitCount`; `bitCount` itself
    ///   denotes the end of the buffer.
    /// - Throws: ``BitLaneError/invalidPosition(position:bitCount:)`` if `offset`
    ///   is out of range.
    /// - Complexity: O(1).
    public mutating func seek(toBit offset: Int) throws {
        guard offset >= 0 && offset <= bitCount else {
            throw BitLaneError.invalidPosition(position: offset, bitCount: bitCount)
        }
        bitPosition = offset
    }

    /// Moves the cursor by a signed number of bits: forward when positive,
    /// backward when negative.
    ///
    /// - Parameter bits: The signed distance to move. The resulting position must
    ///   land in `0...bitCount`.
    /// - Throws: ``BitLaneError/invalidPosition(position:bitCount:)`` if the move
    ///   would leave the valid range.
    /// - Complexity: O(1).
    public mutating func skip(bits: Int) throws {
        let target = bitPosition + bits
        guard target >= 0 && target <= bitCount else {
            throw BitLaneError.invalidPosition(position: target, bitCount: bitCount)
        }
        bitPosition = target
    }

    /// Returns the cursor to the start of the buffer.
    ///
    /// - Complexity: O(1).
    public mutating func reset() {
        bitPosition = 0
    }

    /// Advances the cursor to the next byte boundary, discarding up to seven
    /// padding bits. A no-op when already byte-aligned.
    ///
    /// - Returns: The number of padding bits skipped, in `0...7`.
    /// - Throws: ``BitLaneError/insufficientBits(requested:available:)`` if the
    ///   buffer ends before the next byte boundary.
    /// - Complexity: O(1).
    @discardableResult
    public mutating func alignToByte() throws -> Int {
        let misalignment = bitPosition & 7
        guard misalignment != 0 else { return 0 }

        let padding = 8 - misalignment
        let available = bitCount - bitPosition
        guard padding <= available else {
            throw BitLaneError.insufficientBits(requested: padding, available: available)
        }
        bitPosition += padding
        return padding
    }

    /// Reads `count` whole bytes as `Data`, MSB first.
    ///
    /// When the cursor is byte-aligned the payload is copied a machine word at a
    /// time. See ``readBytes(_:)`` for a `[UInt8]` result.
    ///
    /// - Parameter count: The number of bytes to read.
    /// - Returns: The `count` bytes read.
    /// - Throws: ``BitLaneError/negativeCount(_:)`` if `count` is negative;
    ///   ``BitLaneError/insufficientBits(requested:available:)`` if fewer than
    ///   `count * 8` bits remain.
    /// - Complexity: O(n) in `count`.
    public mutating func readData(_ count: Int) throws -> Data {
        try checkReadable(count)
        guard count > 0 else { return Data() }
        var out = Data(count: count)
        try out.withUnsafeMutableBytes { try fillBytes($0) }
        return out
    }

    /// Reads `count` whole bytes as `[UInt8]`, MSB first.
    ///
    /// - Parameter count: The number of bytes to read.
    /// - Returns: The `count` bytes read.
    /// - Throws: ``BitLaneError/negativeCount(_:)`` if `count` is negative;
    ///   ``BitLaneError/insufficientBits(requested:available:)`` if fewer than
    ///   `count * 8` bits remain.
    /// - Complexity: O(n) in `count`.
    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        try checkReadable(count)
        guard count > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: count)
        try out.withUnsafeMutableBytes { try fillBytes($0) }
        return out
    }

    /// Validates that `count` whole bytes can be read from the current position.
    private func checkReadable(_ count: Int) throws {
        guard count >= 0 else { throw BitLaneError.negativeCount(count) }
        let available = bitCount - bitPosition
        guard count * 8 <= available else {
            throw BitLaneError.insufficientBits(requested: count * 8, available: available)
        }
    }

    /// Reads `dst.count` bytes into `dst`, advancing the cursor. Shared by
    /// ``readData(_:)`` and ``readBytes(_:)``; the caller must have verified that
    /// enough bits remain.
    private mutating func fillBytes(_ dst: UnsafeMutableRawBufferPointer) throws {
        let count = dst.count
        guard count > 0, let base = dst.baseAddress else { return }

        // Not byte-aligned: every byte straddles a word boundary, so read singly.
        if bitPosition & 7 != 0 {
            for o in 0..<count {
                let byte = try read(bits: 8)
                base.storeBytes(of: UInt8(truncatingIfNeeded: byte), toByteOffset: o, as: UInt8.self)
            }
            return
        }

        var o = 0
        // Head: bytes until the cursor is word-aligned.
        while bitPosition & 63 != 0 && o < count {
            base.storeBytes(of: UInt8(truncatingIfNeeded: words[bitPosition >> 6] >> (56 - (bitPosition & 63))),
                            toByteOffset: o, as: UInt8.self)
            bitPosition += 8
            o += 1
        }
        // Body: whole words copied straight out, big-endian.
        let fullWords = (count - o) >> 3
        for _ in 0..<fullWords {
            var be = words[bitPosition >> 6].bigEndian
            withUnsafeBytes(of: &be) {
                base.advanced(by: o).copyMemory(from: $0.baseAddress!, byteCount: 8)
            }
            bitPosition += 64
            o += 8
        }
        // Tail: remaining bytes one at a time.
        while o < count {
            base.storeBytes(of: UInt8(truncatingIfNeeded: words[bitPosition >> 6] >> (56 - (bitPosition & 63))),
                            toByteOffset: o, as: UInt8.self)
            bitPosition += 8
            o += 1
        }
    }
}

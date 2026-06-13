import Foundation

/// A high-performance, MSB-first bit stream writer.
///
/// `BitWriter` packs values of arbitrary bit width into a compact buffer. Bits
/// are written most-significant-bit first, so insertion order is preserved:
///
/// ```swift
/// var writer = BitWriter()
/// try writer.write(0b101, bits: 3)   // buffer: 101
/// try writer.write(0b11,  bits: 2)   // buffer: 10111
/// let data = writer.data()           // 0b1011_1000 -> [0xB8]
/// ```
///
/// Bits accumulate in an array of `UInt64` words, each filled from its most
/// significant bit down; a new word is allocated only when the current one is
/// full, and conversion to `Data` happens only in ``data()``. Each
/// `write(_:bits:)` is `O(1)` and touches at most two words.
///
/// `BitWriter` is a value type with copy-on-write storage, so copies are
/// independent.
public struct BitWriter: Sendable {

    /// The backing storage. Bits are packed MSB-first within each word.
    var words: [UInt64]

    /// The total number of bits written. Also the cursor: the word being filled
    /// is `bitCount >> 6` and the in-word offset is `bitCount & 63`.
    public private(set) var bitCount: Int

    /// Creates an empty writer.
    public init() {
        self.words = []
        self.bitCount = 0
    }

    /// Creates an empty writer with storage pre-allocated for at least `capacity`
    /// bits.
    ///
    /// - Parameter capacity: The expected number of bits.
    /// - Throws: ``BitLaneError/negativeCount(_:)`` if `capacity` is negative.
    public init(reservingBitCapacity capacity: Int) throws {
        guard capacity >= 0 else { throw BitLaneError.negativeCount(capacity) }
        self.words = []
        self.words.reserveCapacity((capacity + 63) >> 6)
        self.bitCount = 0
    }

    /// The number of bytes ``data()`` would currently produce.
    public var byteCount: Int {
        (bitCount + 7) >> 3
    }

    /// A Boolean value indicating whether no bits have been written.
    public var isEmpty: Bool {
        bitCount == 0
    }

    /// Reserves storage for at least `bits` additional bits.
    ///
    /// - Parameter bits: The number of additional bits to make room for.
    /// - Throws: ``BitLaneError/negativeCount(_:)`` if `bits` is negative.
    public mutating func reserveCapacity(bits: Int) throws {
        guard bits >= 0 else { throw BitLaneError.negativeCount(bits) }
        words.reserveCapacity((bitCount + bits + 63) >> 6)
    }

    /// Appends the low `bits` bits of `value`, most-significant bit first.
    ///
    /// Only the lowest `bits` bits are written; higher bits are ignored.
    ///
    /// - Parameters:
    ///   - value: The bits to append, right-aligned.
    ///   - bits: The number of bits to append, in `0...64`. Writing `0` is a no-op.
    /// - Throws: ``BitLaneError/invalidBitWidth(bits:max:)`` if `bits` is outside
    ///   `0...64`.
    /// - Complexity: O(1) – at most two words are modified.
    public mutating func write(_ value: UInt64, bits: Int) throws {
        guard bits >= 0 && bits <= 64 else {
            throw BitLaneError.invalidBitWidth(bits: bits, max: 64)
        }
        guard bits > 0 else { return }

        // Keep only the meaningful low bits. `(1 << 64) &- 1` wraps to the full
        // mask, so this is correct for every width in 1...64.
        let mask = (UInt64(1) << bits) &- 1
        let masked = value & mask

        let wordIndex = bitCount >> 6
        let bitIndex = bitCount & 63
        let space = 64 - bitIndex

        if bits <= space {
            // Fits within the current word, possibly filling it exactly.
            if bitIndex == 0 { words.append(0) }
            words[wordIndex] |= masked << (space - bits)
        } else {
            // Spans the boundary: high part finishes this word, low part starts
            // the next. `bitIndex > 0` here, so the current word already exists.
            let lowBits = bits - space
            words[wordIndex] |= masked >> lowBits
            words.append(masked << (64 - lowBits))
        }
        bitCount += bits
    }

    /// Appends the low `bits` bits of any fixed-width integer, MSB first.
    ///
    /// For signed values these are the usual two's-complement low bits.
    ///
    /// - Parameters:
    ///   - value: The bits to append, right-aligned.
    ///   - bits: The number of bits to append, in `0...value.bitWidth`.
    /// - Throws: ``BitLaneError/invalidBitWidth(bits:max:)`` if `bits` is outside
    ///   `0...Value.bitWidth`.
    /// - Complexity: O(1).
    public mutating func write<Value: FixedWidthInteger>(_ value: Value, bits: Int) throws {
        guard bits >= 0 && bits <= Value.bitWidth else {
            throw BitLaneError.invalidBitWidth(bits: bits, max: Value.bitWidth)
        }
        try write(UInt64(truncatingIfNeeded: value), bits: bits)
    }

    /// Appends a single bit. Always succeeds — there is always room to append.
    ///
    /// - Parameter bit: `true` writes a `1`; `false` writes a `0`.
    /// - Complexity: O(1).
    public mutating func write(_ bit: Bool) {
        // A single bit never spans a word boundary and needs no mask.
        let wordIndex = bitCount >> 6
        let bitIndex = bitCount & 63
        if bitIndex == 0 { words.append(0) }
        if bit { words[wordIndex] |= UInt64(1) << (63 - bitIndex) }
        bitCount += 1
    }

    /// Appends zero bits up to the next byte boundary, returning how many were
    /// added (`0...7`). A no-op when already byte-aligned. The mirror of
    /// ``BitReader/alignToByte()``.
    ///
    /// - Complexity: O(1).
    @discardableResult
    public mutating func alignToByte() throws -> Int {
        let misalignment = bitCount & 7
        guard misalignment != 0 else { return 0 }
        let padding = 8 - misalignment
        try write(0 as UInt64, bits: padding)
        return padding
    }

    /// Appends raw bytes, MSB first. When the writer is byte-aligned the payload
    /// is copied a machine word at a time.
    ///
    /// - Parameter bytes: The bytes to append.
    /// - Complexity: O(n) in the number of bytes.
    public mutating func write(contentsOf bytes: Data) throws {
        try bytes.withUnsafeBytes { try writeBytes($0) }
    }

    /// Appends raw bytes, MSB first.
    ///
    /// - Parameter bytes: The bytes to append.
    /// - Complexity: O(n) in the number of bytes.
    public mutating func write(contentsOf bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try writeBytes($0) }
    }

    private mutating func writeBytes(_ raw: UnsafeRawBufferPointer) throws {
        let n = raw.count
        guard n > 0 else { return }

        // When not byte-aligned, every byte straddles a word boundary: no bulk
        // shortcut, write byte by byte.
        guard bitCount & 7 == 0 else {
            for i in 0..<n { try write(UInt64(raw[i]), bits: 8) }
            return
        }

        var i = 0
        // Head: finish the current partial word one byte at a time.
        while bitCount & 63 != 0 && i < n {
            try write(UInt64(raw[i]), bits: 8)
            i += 1
        }

        // Body: append whole 8-byte words. The cursor is word-aligned here.
        let fullWords = (n - i) >> 3
        if fullWords > 0 {
            words.reserveCapacity(words.count + fullWords)
            let base = raw.baseAddress!
            for w in 0..<fullWords {
                var v: UInt64 = 0
                withUnsafeMutableBytes(of: &v) { dst in
                    dst.copyMemory(from: UnsafeRawBufferPointer(
                        start: base.advanced(by: i + (w << 3)), count: 8))
                }
                // `bigEndian` places source byte 0 in the most-significant byte,
                // matching the bitstream's MSB-first ordering on either endianness.
                words.append(v.bigEndian)
            }
            i += fullWords << 3
            bitCount += fullWords << 6
        }

        // Tail: remaining bytes, one at a time.
        while i < n {
            try write(UInt64(raw[i]), bits: 8)
            i += 1
        }
    }

    /// Returns the written bits packed into `Data`, MSB first.
    ///
    /// The result is exactly ``byteCount`` bytes; if ``bitCount`` is not a
    /// multiple of eight, the final byte is zero-padded in its low bits.
    ///
    /// - Complexity: O(n) in the number of words.
    public func data() -> Data {
        let count = byteCount
        guard count > 0 else { return Data() }

        // Write each word's big-endian bytes into the output buffer. `copyMemory`
        // performs the whole-word stores, so the buffer needs no special alignment.
        var result = Data(count: count)
        result.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let base = dst.baseAddress!
            let fullWords = count >> 3
            for i in 0..<fullWords {
                var be = words[i].bigEndian
                withUnsafeBytes(of: &be) {
                    base.advanced(by: i << 3).copyMemory(from: $0.baseAddress!, byteCount: 8)
                }
            }
            let rem = count & 7
            if rem != 0 {
                var be = words[fullWords].bigEndian
                withUnsafeBytes(of: &be) { src in
                    let tail = base.advanced(by: fullWords << 3)
                    for j in 0..<rem {
                        tail.storeBytes(of: src[j], toByteOffset: j, as: UInt8.self)
                    }
                }
            }
        }
        return result
    }
}

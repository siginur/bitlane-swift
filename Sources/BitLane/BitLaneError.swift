/// Errors thrown by ``BitReader`` and ``BitWriter``.
///
/// Every recoverable failure — running out of bits, an out-of-range width,
/// position, or count — is reported as one of these cases so it can be caught
/// rather than trapping.
public enum BitLaneError: Error, Equatable, Sendable {

    /// A read requested more bits than remain in the buffer.
    case insufficientBits(requested: Int, available: Int)

    /// A bit width was outside the valid range `0...max`.
    case invalidBitWidth(bits: Int, max: Int)

    /// A cursor move targeted a position outside `0...bitCount`.
    case invalidPosition(position: Int, bitCount: Int)

    /// A count or capacity argument was negative.
    case negativeCount(Int)
}

extension BitLaneError: CustomStringConvertible {

    public var description: String {
        switch self {
        case let .insufficientBits(requested, available):
            return "BitLaneError.insufficientBits: requested \(requested) bit(s) but only \(available) remain"
        case let .invalidBitWidth(bits, max):
            return "BitLaneError.invalidBitWidth: bit width \(bits) is outside 0...\(max)"
        case let .invalidPosition(position, bitCount):
            return "BitLaneError.invalidPosition: position \(position) is outside 0...\(bitCount)"
        case let .negativeCount(count):
            return "BitLaneError.negativeCount: \(count) must be non-negative"
        }
    }
}

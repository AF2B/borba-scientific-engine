public import Foundation

/// Produces the identifiers of records and events.
///
/// Identifier creation is a port so that tests can predict identifiers and so that ordering guarantees (see
/// ``UUIDv7Generator``) are an explicit property of the implementation, not an accident of `UUID()`.
public protocol IdentifierGenerator: Sendable {
    /// Creates a new, unique identifier.
    func next() -> UUID
}

/// Generates version 7 UUIDs (RFC 9562): a 48-bit Unix timestamp in milliseconds followed by random bits.
///
/// Because the timestamp leads, identifiers created later sort after identifiers created earlier, which keeps
/// B-tree indexes append-mostly and makes the identifier a usable pagination tiebreaker. Two identifiers created
/// within the same millisecond are ordered randomly relative to each other, which is why history is ordered by
/// `(created_at, id)` and not by `id` alone.
public struct UUIDv7Generator: IdentifierGenerator {
    private static let timestampByteCount = 6
    private static let byteMask: UInt64 = 0xFF
    private static let bitsPerByte: UInt64 = 8
    private static let millisecondsPerSecond = 1_000.0
    private static let versionByteIndex = 6
    private static let variantByteIndex = 8
    private static let versionNibble: UInt8 = 0x70
    private static let versionMask: UInt8 = 0x0F
    private static let variantBits: UInt8 = 0x80
    private static let variantMask: UInt8 = 0x3F

    private let clock: any EngineClock

    /// Creates a generator that timestamps identifiers with the given clock.
    ///
    /// - Parameter clock: The time source of the identifiers.
    public init(clock: any EngineClock) {
        self.clock = clock
    }

    /// Creates a UUID whose leading bits are the current time.
    public func next() -> UUID {
        var random = SystemRandomNumberGenerator()
        var bytes = (0..<MemoryLayout<uuid_t>.size).map { _ in UInt8.random(in: .min ... .max, using: &random) }

        let milliseconds = UInt64(max(clock.currentDate().timeIntervalSince1970 * Self.millisecondsPerSecond, 0))
        for index in 0..<Self.timestampByteCount {
            let shift = UInt64(Self.timestampByteCount - 1 - index) * Self.bitsPerByte
            bytes[index] = UInt8((milliseconds >> shift) & Self.byteMask)
        }
        bytes[Self.versionByteIndex] = (bytes[Self.versionByteIndex] & Self.versionMask) | Self.versionNibble
        bytes[Self.variantByteIndex] = (bytes[Self.variantByteIndex] & Self.variantMask) | Self.variantBits

        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}

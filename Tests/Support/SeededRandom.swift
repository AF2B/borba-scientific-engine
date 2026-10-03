/// A small deterministic random number generator (SplitMix64), so property-style tests are reproducible.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    /// Creates a generator.
    ///
    /// - Parameter seed: The starting state; the same seed always yields the same sequence.
    public init(seed: UInt64) {
        state = seed
    }

    /// Produces the next 64 random bits.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

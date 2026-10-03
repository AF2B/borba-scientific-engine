/// Neumaier's compensated summation.
///
/// Adding many doubles naively accumulates rounding error that grows with the length of the list; the compensation
/// term recovers the low-order bits each addition loses, so the result is accurate to about one rounding of the true
/// sum regardless of the number of terms or the order they arrive in.
struct CompensatedSum {
    private var sum = 0.0
    private var compensation = 0.0

    /// The accumulated total.
    var value: Double {
        sum + compensation
    }

    /// Adds one term.
    ///
    /// - Parameter term: The number to add.
    mutating func add(_ term: Double) {
        let total = sum + term
        if abs(sum) >= abs(term) {
            compensation += (sum - total) + term
        } else {
            compensation += (term - total) + sum
        }
        sum = total
    }

    /// Sums a sequence of numbers.
    ///
    /// - Parameter terms: The numbers to add.
    /// - Returns: The compensated total.
    static func total(of terms: some Sequence<Double>) -> Double {
        var accumulator = CompensatedSum()
        for term in terms {
            accumulator.add(term)
        }
        return accumulator.value
    }
}

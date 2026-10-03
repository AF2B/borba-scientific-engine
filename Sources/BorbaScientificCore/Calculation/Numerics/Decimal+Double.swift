import Foundation

extension Decimal {
    /// The `Double` nearest to this decimal.
    ///
    /// `NSDecimalNumber.doubleValue` scales the mantissa by a power of ten in floating point, which can land one
    /// unit in the last place away from the intended value (`1073.64` becoming `1073.6399999999999`). Parsing the
    /// decimal text instead is correctly rounded, so amounts serialize exactly as they were written.
    var nearestDouble: Double {
        Double(description) ?? .nan
    }
}

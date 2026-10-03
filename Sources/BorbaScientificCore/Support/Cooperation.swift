/// Cooperative cancellation for CPU-bound loops.
///
/// Swift cancellation is cooperative: a time budget or a client disconnect only takes effect when the running code
/// looks for it. Loops whose cost grows with the input call ``checkpoint(iteration:)`` so the engine can stop them.
public enum Cooperation {
    /// Number of iterations between cancellation checks. Checking on every iteration would dominate cheap loops.
    public static let checkInterval = 1_024

    /// Throws when the surrounding task was cancelled, checking only every ``checkInterval`` iterations.
    ///
    /// - Parameter iteration: The zero-based index of the current loop iteration.
    /// - Throws: ``CalculationError/cancelled`` when the task has been cancelled.
    public static func checkpoint(iteration: Int) throws(CalculationError) {
        guard iteration.isMultiple(of: checkInterval), Task.isCancelled else {
            return
        }
        throw .cancelled
    }
}

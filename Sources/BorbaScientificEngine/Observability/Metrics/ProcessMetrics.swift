import Foundation
import Synchronization

/// A point-in-time reading of the process's own resource use.
struct ProcessSnapshot: Sendable, Equatable {
    /// Resident memory, in bytes.
    let residentMemoryBytes: Double

    /// CPU time spent in user and kernel mode, in seconds, since the process started.
    let cpuSeconds: Double

    /// File descriptors currently open.
    let openFileDescriptors: Double
}

/// Reads the process's resource use from `/proc` on Linux, which is where the service runs. On other systems it reports
/// nothing, and the metrics simply are not published.
enum ProcessMetrics {
    private static let statmPath = "/proc/self/statm"
    private static let statPath = "/proc/self/stat"
    private static let descriptorsPath = "/proc/self/fd"

    /// Field indexes in `/proc/self/statm`: size, resident, shared, text, lib, data, dt (in pages).
    private static let residentPagesField = 1

    /// Fields of `/proc/self/stat` counted after the command name, which is parenthesised and may contain spaces:
    /// `state` is field 0, so `utime` (field 14 overall) is 11 and `stime` (field 15) is 12.
    private static let userTimeField = 11
    private static let systemTimeField = 12

    /// Reads the current values.
    ///
    /// - Returns: The snapshot, or `nil` when `/proc` is not available.
    static func read() -> ProcessSnapshot? {
        guard
            let statm = try? String(contentsOfFile: statmPath, encoding: .utf8),
            let stat = try? String(contentsOfFile: statPath, encoding: .utf8),
            let resident = residentMemory(statm: statm, pageSize: Double(sysconf(Int32(_SC_PAGESIZE)))),
            let cpu = cpuSeconds(stat: stat, ticksPerSecond: Double(sysconf(Int32(_SC_CLK_TCK))))
        else {
            return nil
        }

        let descriptors = (try? FileManager.default.contentsOfDirectory(atPath: descriptorsPath).count) ?? 0
        return ProcessSnapshot(
            residentMemoryBytes: resident,
            cpuSeconds: cpu,
            openFileDescriptors: Double(descriptors)
        )
    }

    /// Resident memory from the contents of `/proc/self/statm`.
    ///
    /// - Parameters:
    ///   - statm: The file's contents.
    ///   - pageSize: The size of a memory page, in bytes.
    /// - Returns: The resident set size in bytes, or `nil` when the text is not in the expected form.
    static func residentMemory(
        statm: String,
        pageSize: Double
    ) -> Double? {
        let fields = statm.split(separator: " ")

        guard fields.indices.contains(residentPagesField), let pages = Double(fields[residentPagesField]) else {
            return nil
        }
        return pages * pageSize
    }

    /// CPU time from the contents of `/proc/self/stat`.
    ///
    /// - Parameters:
    ///   - stat: The file's contents.
    ///   - ticksPerSecond: How many clock ticks make a second.
    /// - Returns: User plus kernel time in seconds, or `nil` when the text is not in the expected form.
    static func cpuSeconds(
        stat: String,
        ticksPerSecond: Double
    ) -> Double? {
        // The command name is wrapped in parentheses and can contain spaces, so counting starts after the last one.
        guard let closing = stat.lastIndex(of: ")") else {
            return nil
        }
        let fields = stat[stat.index(after: closing)...].split(separator: " ")

        guard
            fields.indices.contains(systemTimeField),
            let user = Double(fields[userTimeField]),
            let system = Double(fields[systemTimeField]),
            ticksPerSecond > 0
        else {
            return nil
        }
        return (user + system) / ticksPerSecond
    }
}

/// Publishes the process's resource use, remembering how much CPU time it has already published so the counter only
/// ever goes up by the difference.
final class ProcessMetricsRecorder: Sendable {
    private let publishedCPUSeconds = Mutex(0.0)

    /// Reads the process and records what it finds.
    ///
    /// - Parameter metrics: Where the values are recorded. Nothing is recorded where `/proc` is not available.
    func refresh(into metrics: EngineMetrics) {
        guard let snapshot = ProcessMetrics.read() else {
            return
        }

        metrics.setProcessGauge(MetricName.processResidentMemory, snapshot.residentMemoryBytes)
        metrics.setProcessGauge(MetricName.processOpenFileDescriptors, snapshot.openFileDescriptors)

        let delta = publishedCPUSeconds.withLock { published -> Double in
            let increase = max(snapshot.cpuSeconds - published, 0)
            published += increase
            return increase
        }
        metrics.addProcessCPUSeconds(delta)
    }
}

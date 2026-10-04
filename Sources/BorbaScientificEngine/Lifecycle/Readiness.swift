import BorbaScientificCore
import BorbaScientificPersistence

/// What one readiness probe found.
struct ReadinessCheckResult: Sendable, Equatable {
    /// Whether the thing probed can serve traffic.
    enum State: String, Sendable, Equatable, Encodable {
        case up
        case down
    }

    /// What was probed, such as `database`.
    let name: String

    /// The verdict.
    let state: State

    /// Why it is down, in a fixed vocabulary that is safe to expose; never a host name or an error text.
    let detail: String?
}

/// Something the service needs in order to serve traffic.
protocol ReadinessProbe: Sendable {
    /// What is probed, such as `database`.
    var name: String { get }

    /// Looks. Never throws: a dependency that does not answer is the answer.
    func check() async -> ReadinessCheckResult
}

/// What readiness found, as a whole.
struct ReadinessReport: Sendable, Equatable {
    /// The shutdown check's name.
    static let shutdownCheckName = "lifecycle"

    /// The detail of a service that is shutting down.
    static let shuttingDownDetail = "shutting down"

    /// One result per probe.
    let checks: [ReadinessCheckResult]

    /// Whether every probe is up.
    var isReady: Bool {
        checks.allSatisfy { $0.state == .up }
    }

    /// The report of a process that has begun to shut down.
    static let shuttingDown = ReadinessReport(
        checks: [ReadinessCheckResult(name: shutdownCheckName, state: .down, detail: shuttingDownDetail)]
    )
}

/// Probes PostgreSQL: it must answer, and its schema must be the one the code expects.
struct DatabaseReadinessProbe: ReadinessProbe {
    let name = "database"

    private let health: DatabaseHealth

    /// Creates the probe.
    ///
    /// - Parameter health: Checks connectivity and migrations.
    init(health: DatabaseHealth) {
        self.health = health
    }

    /// Checks the database.
    ///
    /// - Returns: Up when it answers with every migration applied; otherwise down, saying which of the two failed.
    func check() async -> ReadinessCheckResult {
        let report = await health.check()

        switch report.status {
        case .healthy:
            return ReadinessCheckResult(name: name, state: .up, detail: nil)
        case .unreachable:
            return ReadinessCheckResult(name: name, state: .down, detail: "unreachable")
        case .migrationsPending:
            return ReadinessCheckResult(name: name, state: .down, detail: "migrations pending")
        }
    }
}

/// Answers whether the service should be sent traffic, cheaply and without ever piling up behind a slow dependency.
///
/// Orchestrators probe often and from several places, and the probes run precisely when a dependency is struggling.
/// If each probe cost a database round trip, the probes themselves would eat the connection pool of a database that
/// is already slow. The service therefore:
///
/// - **coalesces** concurrent probes into one (single flight): callers that arrive while a check runs wait for its
///   answer instead of starting their own;
/// - **remembers** the answer briefly, so a burst of probes costs one check;
/// - **bounds** every check in time, so a dependency that does not answer is reported down instead of hanging;
/// - **never caches the shutdown state**: once the process is stopping it answers "not ready" immediately.
///
/// It is an actor because the cached report and the check in flight are mutable state shared by every probe request.
actor ReadinessService {
    private let probes: [any ReadinessProbe]
    private let shutdown: ShutdownState
    private let timeToLive: Duration
    private let probeTimeout: Duration
    private let clock: any EngineClock

    private var cached: (report: ReadinessReport, takenAt: Duration)?
    private var inFlight: Task<ReadinessReport, Never>?

    /// Creates the service.
    ///
    /// - Parameters:
    ///   - probes: What must be up for the service to be ready.
    ///   - shutdown: Whether the process is stopping.
    ///   - timeToLive: How long an answer is reused.
    ///   - probeTimeout: The longest a probe may take before it is reported down.
    ///   - clock: Measures the lifetime of answers and the time limit of probes.
    init(
        probes: [any ReadinessProbe],
        shutdown: ShutdownState,
        timeToLive: Duration,
        probeTimeout: Duration,
        clock: any EngineClock
    ) {
        self.probes = probes
        self.shutdown = shutdown
        self.timeToLive = timeToLive
        self.probeTimeout = probeTimeout
        self.clock = clock
    }

    /// The current answer.
    ///
    /// - Returns: The report of the latest check, which is at most `timeToLive` old, or the shutting-down report.
    func report() async -> ReadinessReport {
        if shutdown.isShuttingDown {
            return .shuttingDown
        }
        if let cached, clock.uptime() - cached.takenAt < timeToLive {
            return cached.report
        }
        if let inFlight {
            return await inFlight.value
        }

        let probes = probes
        let timeout = probeTimeout
        let clock = clock
        let check = Task { await Self.run(probes, within: timeout, clock: clock) }

        inFlight = check
        let report = await check.value
        cached = (report, clock.uptime())
        inFlight = nil
        return report
    }

    private static func run(
        _ probes: [any ReadinessProbe],
        within timeout: Duration,
        clock: any EngineClock
    ) async -> ReadinessReport {
        await withTaskGroup(of: (index: Int, result: ReadinessCheckResult).self) { group in
            for (index, probe) in probes.enumerated() {
                group.addTask { (index, await bounded(probe, within: timeout, clock: clock)) }
            }

            var results = [ReadinessCheckResult?](repeating: nil, count: probes.count)
            for await (index, result) in group {
                results[index] = result
            }
            return ReadinessReport(checks: results.compactMap { $0 })
        }
    }

    private static func bounded(
        _ probe: any ReadinessProbe,
        within timeout: Duration,
        clock: any EngineClock
    ) async -> ReadinessCheckResult {
        await Race.firstToFinish(
            { await probe.check() },
            {
                try? await clock.sleep(for: timeout)
                return ReadinessCheckResult(name: probe.name, state: .down, detail: "timed out")
            }
        )
    }
}

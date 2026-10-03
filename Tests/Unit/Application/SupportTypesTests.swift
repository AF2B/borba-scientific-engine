import Foundation
import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("UUIDv7Generator")
struct UUIDv7GeneratorTests {
    private func bytes(of uuid: UUID) -> [UInt8] {
        withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    @Test("sets the version and variant bits")
    func versionAndVariant() {
        let generator = UUIDv7Generator(clock: ManualClock(date: RecordFixtures.epoch))

        for _ in 0..<100 {
            let bytes = bytes(of: generator.next())

            #expect(bytes[6] >> 4 == 0b0111, "version 7")
            #expect(bytes[8] >> 6 == 0b10, "RFC 9562 variant")
        }
    }

    @Test("leads with the clock's Unix time in milliseconds")
    func timestampPrefix() {
        let clock = ManualClock(date: Date(timeIntervalSince1970: 1_700_000_000.123))
        let generator = UUIDv7Generator(clock: clock)

        let bytes = bytes(of: generator.next())
        let milliseconds = bytes[0..<6].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }

        #expect(milliseconds == 1_700_000_000_123)
    }

    @Test("identifiers created later sort after identifiers created earlier")
    func ordering() {
        let clock = ManualClock(date: RecordFixtures.epoch)
        let generator = UUIDv7Generator(clock: clock)
        var identifiers: [CalculationID] = []

        for _ in 0..<50 {
            identifiers.append(CalculationID(generator.next()))
            clock.advance(by: .milliseconds(2))
        }

        #expect(identifiers == identifiers.sorted())
    }

    @Test("does not collide within one millisecond")
    func uniqueness() {
        let generator = UUIDv7Generator(clock: ManualClock(date: RecordFixtures.epoch))

        let identifiers = Set((0..<10_000).map { _ in generator.next() })

        #expect(identifiers.count == 10_000)
    }

    @Test("sequential identifiers are predictable")
    func sequential() {
        let identifiers = SequentialIdentifiers()

        #expect(identifiers.next().uuidString == "00000000-0000-0000-0000-000000000001")
        #expect(identifiers.next().uuidString == "00000000-0000-0000-0000-000000000002")
    }
}

@Suite("RepositoryError")
struct RepositoryErrorTests {
    @Test(
        "separates failures worth retrying from the rest",
        arguments: [
            (RepositoryError.unavailable(reason: "refused"), true),
            (.timeout, true),
            (.integrity(reason: "unique"), false),
            (.corrupted(reason: "json"), false),
            (.unexpected(reason: "?"), false),
        ]
    )
    func transience(
        error: RepositoryError,
        expectedTransient: Bool
    ) {
        #expect(error.isTransient == expectedTransient)
        #expect(error.code == (expectedTransient ? .storageUnavailable : .storageFailure))
        #expect(error.classification == .infrastructure)
        #expect(error.classification.isReportable)
    }

    @Test("never puts technical detail into the caller-facing message")
    func messagesAreSafe() {
        let secret = "password=hunter2 host=10.0.0.5"

        for error in [
            RepositoryError.unavailable(reason: secret), .integrity(reason: secret), .corrupted(reason: secret),
            .unexpected(reason: secret),
        ] {
            #expect(!error.message.contains(secret))
            #expect(error.diagnostic.contains(secret), "the diagnostic is for logs and does carry detail")
        }
    }
}

@Suite("Error classification")
struct ErrorClassificationTests {
    @Test("reports only infrastructure and unexpected failures")
    func reportable() {
        #expect(ErrorClassification.expectedDomain.isReportable == false)
        #expect(ErrorClassification.application.isReportable == false)
        #expect(ErrorClassification.infrastructure.isReportable)
        #expect(ErrorClassification.unexpected.isReportable)
    }

    @Test("classifies every calculation error")
    func calculationErrors() {
        #expect(CalculationError.numericOverflow.classification == .expectedDomain)
        #expect(CalculationError.timedOut(limit: .seconds(1)).classification == .application)
        #expect(CalculationError.cancelled.classification == .application)
        #expect(CalculationError.internalFailure(reason: "x").classification == .unexpected)
        #expect(CalculationError.undefined("x").classification == .expectedDomain)
    }

    @Test("describes a timeout with its limit")
    func timeoutMessage() {
        #expect(CalculationError.timedOut(limit: .seconds(2)).message.contains("2.0 seconds"))
    }
}

@Suite("Pagination")
struct PaginationTests {
    @Test("clamps the page size into its valid range")
    func clamping() {
        #expect(PageRequest(limit: 0).limit == 1)
        #expect(PageRequest(limit: -5).limit == 1)
        #expect(PageRequest(limit: 50).limit == 50)
        #expect(PageRequest(limit: 10_000).limit == PageRequest.maximumLimit)
        #expect(PageRequest().limit == PageRequest.defaultLimit)
    }

    @Test("orders calculation identifiers chronologically")
    func identifierOrdering() {
        #expect(RecordFixtures.id(1) < RecordFixtures.id(2))
        #expect(RecordFixtures.id(2) < RecordFixtures.id(10))
        #expect(RecordFixtures.id(10).description == "00000000-0000-7000-8000-00000000000a")
    }
}

@Suite("TraceContext")
struct TraceContextTests {
    private let context = TraceContext(requestID: RequestID("r-1"), correlationID: CorrelationID("c-1"))

    @Test("is absent until bound and absent again afterwards")
    func binding() async {
        #expect(TraceContext.current == nil)

        let inside = await TraceContext.withValue(context) { TraceContext.current }

        #expect(inside == context)
        #expect(TraceContext.current == nil)
    }

    @Test("is inherited by child tasks and not by detached ones")
    func inheritance() async {
        let (child, grandchild, detached) = await TraceContext.withValue(context) {
            async let child = TraceContext.current
            let grandchild = await withTaskGroup(of: TraceContext?.self) { group in
                group.addTask { TraceContext.current }
                for await value in group {
                    return value
                }
                return nil
            }
            let detached = await Task.detached { TraceContext.current }.value
            return (await child, grandchild, detached)
        }

        #expect(child == context)
        #expect(grandchild == context)
        #expect(detached == nil)
    }

    @Test("keeps concurrent requests apart")
    func isolation() async {
        let contexts = (0..<20).map {
            TraceContext(requestID: RequestID("request-\($0)"), correlationID: CorrelationID("correlation-\($0)"))
        }

        let observed = await withTaskGroup(of: (TraceContext, TraceContext?).self) { group in
            for context in contexts {
                group.addTask {
                    await TraceContext.withValue(context) {
                        await Task.yield()
                        return (context, TraceContext.current)
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(observed.count == contexts.count)
        #expect(observed.allSatisfy { $0.0 == $0.1 })
    }
}

@Suite("In-memory repository")
struct InMemoryRepositoryContractTests {
    @Test("honours the repository contract")
    func contract() async throws {
        try await RepositoryContract.verify { InMemoryCalculationRepository() }
    }
}

import Testing

@testable import BorbaScientificEngine

@Suite("HealthProbe addresses")
struct HealthProbeAddressTests {
    private static let port = 9_090
    private static let specificHost = "10.0.0.5"
    private static let ipv6Loopback = "::1"
    private static let wildcardHosts = ["0.0.0.0", "::"]

    private func settings(host: String? = nil) throws -> HTTPSettings {
        var variables: [EnvironmentVariable: String] = [
            .databaseURL: ConfigurationFixture.databaseURL,
            .httpPort: String(Self.port),
        ]
        variables[.httpHost] = host

        return try ConfigurationLoader.load(from: ConfigurationFixture.environment(variables)).http
    }

    @Test("reaches a server that listens on every interface through loopback", arguments: wildcardHosts)
    func wildcard(host: String) throws {
        let url = HealthProbe.healthURL(for: try settings(host: host))

        #expect(url == "http://\(ConfigurationDefaults.loopbackHost):\(Self.port)/health")
    }

    @Test("keeps the address a server is bound to")
    func specific() throws {
        let url = HealthProbe.healthURL(for: try settings(host: Self.specificHost))

        #expect(url == "http://\(Self.specificHost):\(Self.port)/health")
    }

    @Test("puts an IPv6 address in brackets")
    func ipv6() throws {
        let url = HealthProbe.healthURL(for: try settings(host: Self.ipv6Loopback))

        #expect(url == "http://[\(Self.ipv6Loopback)]:\(Self.port)/health")
    }

    @Test("probes the address the server uses by default when nothing is configured")
    func defaults() throws {
        let configured = try ConfigurationLoader.load(from: ConfigurationFixture.minimal).http

        let url = HealthProbe.healthURL(for: configured)

        #expect(url == "http://\(ConfigurationDefaults.loopbackHost):\(ConfigurationDefaults.httpPort)/health")
    }
}

@Suite("HealthProbeFailure")
struct HealthProbeFailureTests {
    @Test("says what the instance answered")
    func unexpectedStatus() {
        #expect(HealthProbeFailure.unexpectedStatus(503).description == "answered with status 503")
    }

    @Test("says why nothing answered")
    func unreachable() {
        #expect(HealthProbeFailure.unreachable("connection refused").description == "no answer: connection refused")
    }
}

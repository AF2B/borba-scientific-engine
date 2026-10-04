import Foundation

/// What a scrape of `/metrics` contained.
public struct MetricsScrape: Sendable {
    private struct Sample: Sendable {
        let name: String
        let labels: [String: String]
        let value: Double
    }

    private let samples: [Sample]

    /// Parses the Prometheus text exposition format.
    ///
    /// - Parameter text: The body of a `/metrics` response.
    public init(_ text: String) {
        samples = text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else {
                return nil
            }
            return Self.parse(String(line))
        }
    }

    /// The value of the sample with exactly these labels.
    ///
    /// - Parameters:
    ///   - name: The sample's name, including any `_bucket`, `_sum` or `_count` suffix.
    ///   - labels: The labels it must carry; others it may carry as well are ignored.
    /// - Returns: The value, or `nil` when there is no such sample.
    public func value(
        _ name: String,
        _ labels: [String: String] = [:]
    ) -> Double? {
        samples.first { sample in
            sample.name == name && labels.allSatisfy { key, expected in sample.labels[key] == expected }
        }?.value
    }

    /// How many samples carry a name.
    ///
    /// - Parameter name: The sample's name.
    /// - Returns: The number of samples.
    public func count(named name: String) -> Int {
        samples.filter { $0.name == name }.count
    }

    private static func parse(_ line: String) -> Sample? {
        guard let separator = line.lastIndex(of: " "), let value = Double(line[line.index(after: separator)...]) else {
            return nil
        }
        let head = line[..<separator]
        guard let open = head.firstIndex(of: "{"), let close = head.lastIndex(of: "}") else {
            return Sample(name: String(head), labels: [:], value: value)
        }

        var labels: [String: String] = [:]
        for pair in head[head.index(after: open)..<close].split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                labels[String(parts[0])] = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return Sample(name: String(head[..<open]), labels: labels, value: value)
    }
}

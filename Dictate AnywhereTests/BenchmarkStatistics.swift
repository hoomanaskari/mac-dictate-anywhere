import Foundation

/// Machine-readable, nearest-rank latency summaries for opt-in benchmarks.
/// No threshold is baked in: compare runs from the same device and build.
struct BenchmarkStatistics {
    let milliseconds: [Double]

    init(_ milliseconds: [Double]) {
        precondition(!milliseconds.isEmpty)
        self.milliseconds = milliseconds.sorted()
    }

    var p50: Double { percentile(0.50) }
    var p95: Double { percentile(0.95) }

    private func percentile(_ fraction: Double) -> Double {
        milliseconds[max(0, Int(ceil(Double(milliseconds.count) * fraction)) - 1)]
    }

    func report(component: String, details: String = "") {
        print(
            "PIPELINE_BENCHMARK component=\(component) iterations=\(milliseconds.count) "
            + "p50_ms=\(String(format: "%.3f", p50)) p95_ms=\(String(format: "%.3f", p95)) "
            + "min_ms=\(String(format: "%.3f", milliseconds[0])) "
            + "max_ms=\(String(format: "%.3f", milliseconds[milliseconds.count - 1])) \(details)"
        )
    }

    static func elapsedMilliseconds(from start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}

/// Case- and punctuation-insensitive WER for a supplied exact reference.
/// Values can exceed 1.0 when the hypothesis inserts many words.
func benchmarkWordErrorRate(reference: String, hypothesis: String) -> Double {
    func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    let expected = words(reference)
    let actual = words(hypothesis)
    guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }
    var previous = Array(0...actual.count)
    for (index, word) in expected.enumerated() {
        var next = [index + 1] + [Int](repeating: 0, count: actual.count)
        for (offset, candidate) in actual.enumerated() {
            next[offset + 1] = min(
                previous[offset + 1] + 1,
                next[offset] + 1,
                previous[offset] + (word == candidate ? 0 : 1)
            )
        }
        previous = next
    }
    return Double(previous[actual.count]) / Double(expected.count)
}

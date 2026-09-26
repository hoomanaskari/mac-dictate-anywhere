import XCTest

final class BenchmarkStatisticsTests: XCTestCase {
    func testNearestRankOnSmallAndUnsortedSamples() {
        let summary = BenchmarkStatistics([9, 1, 4, 2, 3])
        XCTAssertEqual(summary.p50, 3)
        XCTAssertEqual(summary.p95, 9)
        XCTAssertEqual(BenchmarkStatistics([7]).p50, 7)
    }

    func testWordErrorRateCountsSubstitutionsInsertionsAndDeletions() {
        XCTAssertEqual(benchmarkWordErrorRate(reference: "Hello, world!", hypothesis: "hello world"), 0)
        XCTAssertEqual(benchmarkWordErrorRate(reference: "one two three", hypothesis: "one four three"), 1.0 / 3)
        XCTAssertEqual(benchmarkWordErrorRate(reference: "one two", hypothesis: "one"), 0.5)
        XCTAssertEqual(benchmarkWordErrorRate(reference: "one", hypothesis: "one two"), 1)
    }
}

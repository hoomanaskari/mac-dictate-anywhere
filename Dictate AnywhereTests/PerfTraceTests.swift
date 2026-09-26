import XCTest
@testable import Dictate_Anywhere

private final class TraceSnapshotStorage: @unchecked Sendable {
    let lock = NSLock()
    var values: [String: String] = [:]
}

final class PerfTraceTests: XCTestCase {
    func testErrorOutcomesIncludeURLSessionCancellation() {
        struct Probe: Error {}
        XCTAssertEqual(String(describing: PerfTrace.outcome(for: CancellationError())), "cancelled")
        XCTAssertEqual(String(describing: PerfTrace.outcome(for: URLError(.cancelled))), "cancelled")
        XCTAssertEqual(String(describing: PerfTrace.outcome(for: Probe())), "failed")
    }

    func testBeginEndIsIdempotent() {
        let interval = PerfTrace.begin("test.manual")
        XCTAssertEqual(interval.end(), PerfTrace.isEnabled)
        XCTAssertFalse(interval.end())
    }

    func testBuildDefaultAndLaunchOverride() {
        #if DISTRIBUTION_BUILD
        XCTAssertFalse(PerfTrace.isEnabled(in: [:]))
        #else
        XCTAssertTrue(PerfTrace.isEnabled(in: [:]))
        #endif
        XCTAssertTrue(PerfTrace.isEnabled(in: ["DICTATE_ANYWHERE_PERF_TRACE": "1"]))
        XCTAssertFalse(PerfTrace.isEnabled(in: ["DICTATE_ANYWHERE_PERF_TRACE": "0"]))
        XCTAssertEqual(PerfTrace.isEnabled, PerfTrace.isEnabled(in: ProcessInfo.processInfo.environment))
    }

    func testSessionMetadataMergesAndFormatsFields() {
        let original = PerfTraceSessionMetadata(labels: ["session_id": "first", "engine": "parakeet"])
        let updated = original.merging(["session_id": "second", "model": "test-model"])
        XCTAssertEqual(original.logFields, "engine=parakeet session_id=first")
        XCTAssertEqual(updated.logFields, "engine=parakeet model=test-model session_id=second")
    }

    func testDisabledIntervalSkipsCountsAndMetadataAndNeverEnds() throws {
        try XCTSkipUnless(!PerfTrace.isEnabled, "Requires disabled tracing")
        var evaluated = false
        func counts() -> [String: Int] {
            evaluated = true
            return ["input_samples": 1]
        }
        let first = PerfTrace.begin("test.disabled", counts: counts())
        let second = PerfTrace.begin("test.disabledOther")
        XCTAssertTrue(first === second)
        first.recordCounts(counts())
        PerfTrace.event("test.disabledEvent", counts: counts())
        PerfTrace.setSessionMetadata(["session_id": { evaluated = true; return "unused" }()])
        PerfTrace.updateSessionMetadata(["engine": { evaluated = true; return "unused" }()])
        first.refreshSessionMetadata()
        XCTAssertFalse(first.end())
        XCTAssertFalse(second.end())
        XCTAssertFalse(evaluated)
    }

    #if DEBUG
    func testEnabledIntervalsSnapshotSessionAndRefreshOnlyWhenRequested() throws {
        try XCTSkipUnless(PerfTrace.isEnabled, "Requires enabled tracing")
        PerfTrace.setSessionMetadata(["session_id": "first", "engine": "old"])
        defer { PerfTrace.clearSessionMetadata(); PerfTrace.onIntervalCompleted = nil }
        let old = PerfTrace.begin("test.oldSession")
        let refreshed = PerfTrace.begin("test.refreshedSession")
        PerfTrace.setSessionMetadata(["session_id": "second", "engine": "new"])
        refreshed.refreshSessionMetadata()
        let snapshots = TraceSnapshotStorage()
        PerfTrace.onIntervalCompleted = { name, _, metadata in
            snapshots.lock.withLock { snapshots.values[name] = metadata }
        }
        XCTAssertTrue(old.end())
        XCTAssertTrue(refreshed.end())
        PerfTrace.setSessionMetadata(["session_id": "third"])
        refreshed.refreshSessionMetadata()
        XCTAssertFalse(refreshed.end())
        XCTAssertTrue(snapshots.lock.withLock { snapshots.values["test.oldSession"]?.contains("session_id=first") == true })
        XCTAssertTrue(snapshots.lock.withLock { snapshots.values["test.refreshedSession"]?.contains("session_id=second") == true })
        XCTAssertTrue(snapshots.lock.withLock { snapshots.values["test.refreshedSession"]?.contains("engine=new") == true })
    }
    #endif

    func testRequestCountsStayOnTheirInterval() {
        let interval = PerfTrace.begin("test.request", counts: ["input_samples": 16_000])
        interval.recordCounts(["new_samples": 8_000])
        XCTAssertEqual(interval.end(outcome: "completed"), PerfTrace.isEnabled)
        interval.recordCounts(["new_samples": 32_000])
        XCTAssertFalse(interval.end())
    }
}

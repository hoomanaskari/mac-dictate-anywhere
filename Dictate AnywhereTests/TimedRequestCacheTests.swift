import XCTest
import os
@testable import Dictate_Anywhere

final class TimedRequestCacheTests: XCTestCase {
    func testExpiryAndCapacityLimitCompletedSnapshots() async throws {
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = TimedRequestCache<String, Int>(lifetime: .seconds(1), capacity: 1,
                                                    now: { clock.withLock { $0 } })
        let load: @Sendable () async throws -> Int = { calls.withLock { $0 += 1; return $0 } }
        let first = try await cache.value(for: "one", load: load)
        let cached = try await cache.value(for: "one", load: load)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(cached, 1)
        clock.withLock { $0 = $0.advanced(by: .seconds(2)) }
        let expired = try await cache.value(for: "one", load: load)
        XCTAssertEqual(expired, 2)
        clock.withLock { $0 = $0.advanced(by: .seconds(1)) }
        let second = try await cache.value(for: "two", load: load)
        let evicted = try await cache.value(for: "one", load: load)
        XCTAssertEqual(second, 3)
        XCTAssertEqual(evicted, 4)
    }

    func testCancelledConsumerDoesNotPoisonSharedLoad() async throws {
        let started = expectation(description: "loader started")
        let cancelled = expectation(description: "cancelled consumer stops before the shared load")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let continuation = OSAllocatedUnfairLock<CheckedContinuation<Int, Never>?>(initialState: nil)
        let cache = TimedRequestCache<String, Int>()
        let load: @Sendable () async throws -> Int = {
            calls.withLock { $0 += 1 }
            return await withCheckedContinuation { resume in
                continuation.withLock { $0 = resume }
                started.fulfill()
            }
        }
        let first = Task {
            do { _ = try await cache.value(for: "shared", load: load); XCTFail("Cancelled consumer returned a value") }
            catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        await fulfillment(of: [started], timeout: 1)
        let second = Task { try await cache.value(for: "shared", load: load) }
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        continuation.withLock { resume in resume?.resume(returning: 42); resume = nil }
        await first.value
        let result = try await second.value
        XCTAssertEqual(result, 42)
        let cached = try await cache.value(for: "shared", load: load)
        XCTAssertEqual(cached, 42)
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testFailedForcedRefreshDiscardsOldSnapshotAndRetries() async throws {
        let cache = TimedRequestCache<String, Int>()
        let initial = try await cache.value(for: "model") { 1 }
        XCTAssertEqual(initial, 1)
        do {
            _ = try await cache.value(for: "model", refresh: true) { throw URLError(.cannotConnectToHost) }
            XCTFail("Refresh failure must propagate")
        } catch let error as URLError { XCTAssertEqual(error.code, .cannotConnectToHost) }
        let retry = try await cache.value(for: "model") { 2 }
        XCTAssertEqual(retry, 2, "A failed explicit refresh must not serve the old snapshot")
    }

    func testInvalidationRejectsNonCooperativeOldLoad() async throws {
        let started = expectation(description: "old loader started")
        let continuation = OSAllocatedUnfairLock<CheckedContinuation<Int, Never>?>(initialState: nil)
        let cache = TimedRequestCache<String, Int>()
        let old = Task {
            try await cache.value(for: "model") {
                await withCheckedContinuation { resume in
                    continuation.withLock { $0 = resume }
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        await cache.invalidate("model")
        let fresh = try await cache.value(for: "model") { 99 }
        XCTAssertEqual(fresh, 99)
        continuation.withLock { resume in resume?.resume(returning: 42); resume = nil }
        do { _ = try await old.value; XCTFail("Invalidated load returned a value") }
        catch is CancellationError {}
        let cached = try await cache.value(for: "model") { 100 }
        XCTAssertEqual(cached, 99)
    }
}

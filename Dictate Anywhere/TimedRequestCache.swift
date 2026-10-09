import Foundation

/// Shares successful requests for a bounded interval. Failures are retried,
/// refresh discards completed snapshots, and cancelling a consumer leaves shared work alive.
actor TimedRequestCache<Key: Hashable & Sendable, Value: Sendable> {
    // All request state stays actor-owned. Consumers can stop waiting without
    // cancelling the loader or removing work that another caller can share.
    nonisolated private final class Pending {
        let id = UUID()
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
    }

    private let lifetime: Duration
    private let capacity: Int
    private let now: @Sendable () -> ContinuousClock.Instant
    private var values: [Key: (time: ContinuousClock.Instant, value: Value)] = [:]
    private var pending: [Key: Pending] = [:]

    init(lifetime: Duration = .seconds(300), capacity: Int = 8,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.lifetime = lifetime
        self.capacity = max(1, capacity)
        self.now = now
    }

    func value(for key: Key, refresh: Bool = false,
               load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if refresh { values[key] = nil }
        if let cached = values[key], cached.time.duration(to: now()) < lifetime {
            return cached.value
        }
        let request: Pending
        if let existing = pending[key] {
            request = existing
        } else {
            request = Pending()
            pending[key] = request
            let requestID = request.id
            request.task = Task {
                do {
                    let value = try await load()
                    complete(.success(value), for: key, requestID: requestID)
                } catch {
                    complete(.failure(error), for: key, requestID: requestID)
                }
            }
        }
        let waiterID = UUID()
        let value: Value = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, for: key) }
        }
        try Task.checkCancellation()
        return value
    }

    private func complete(_ result: Result<Value, Error>, for key: Key, requestID: UUID) {
        // Invalidated loaders may ignore cancellation. Their late completion
        // must not repopulate a snapshot or remove a newer request for this key.
        guard let request = pending[key], request.id == requestID else { return }
        pending[key] = nil
        if case .success(let value) = result {
            values[key] = (now(), value)
            if values.count > capacity,
               let oldest = values.min(by: { $0.value.time < $1.value.time })?.key {
                values[oldest] = nil
            }
        }
        request.waiters.values.forEach { $0.resume(with: result) }
    }

    private func cancelWaiter(_ id: UUID, for key: Key) {
        pending[key]?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func invalidate(_ key: Key) {
        values[key] = nil
        if let request = pending.removeValue(forKey: key) {
            request.task?.cancel()
            request.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    func invalidate(where matches: @Sendable (Key) -> Bool) {
        for key in Set(values.keys).union(pending.keys) where matches(key) {
            invalidate(key)
        }
    }
}

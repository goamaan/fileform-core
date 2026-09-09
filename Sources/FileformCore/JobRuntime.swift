// SPDX-License-Identifier: Apache-2.0
import Foundation
import FileformDomain

public struct TransformationJob: Sendable {
    public let id: UUID
    public let events: AsyncStream<TransformationEvent>
}

/// Terminal delivery follows engine cleanup. Slow clients retain at most 256 events.
public actor JobRuntime {
    private let engine: ConversionEngine
    private var tasks: [UUID: Task<Void, Never>] = [:]
    public init(engine: ConversionEngine = ConversionEngine()) { self.engine = engine }

    public func submit(_ request: TransformationRequest) -> TransformationJob {
        let id = UUID()
        let (events, continuation) = AsyncStream<TransformationEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let emitter = JobEventEmitter(jobID: id, continuation: continuation)
        emitter.send(.queued)
        tasks[id] = Task { await self.execute(request, id: id, emitter: emitter) }
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { Task { await self?.cancel(id) } }
        }
        return .init(id: id, events: events)
    }
    public func cancel(_ jobID: UUID) { tasks[jobID]?.cancel() }
    public func cancelAll() { for task in tasks.values { task.cancel() } }
    public var activeJobCount: Int { tasks.count }

    private func execute(_ request: TransformationRequest, id: UUID, emitter: JobEventEmitter) async {
        defer { tasks.removeValue(forKey: id) }
        do {
            try Task.checkCancellation()
            emitter.send(.progress(.init(.inspecting)))
            let plan = try await engine.plan(request)
            try Task.checkCancellation()
            let result = try await engine.run(plan) { emitter.send(.progress($0)) }
            // A committed output stays successful if cancellation races after commit.
            emitter.finish(.completed(result))
        } catch {
            let failure = error as? FileformError ?? (error is CancellationError
                ? FileformError(.cancelled, "Job stopped; owned partial outputs removed.")
                : FileformError(.engineFailed, "The transformation failed."))
            emitter.finish(.failed(failure))
        }
    }
}

/// Synchronous callbacks cannot overtake terminal delivery. All state is locked.
private final class JobEventEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private let jobID: UUID
    private let continuation: AsyncStream<TransformationEvent>.Continuation
    private var sequence: UInt64 = 0
    private var finished = false
    init(jobID: UUID, continuation: AsyncStream<TransformationEvent>.Continuation) {
        self.jobID = jobID; self.continuation = continuation
    }
    func send(_ payload: TransformationEventPayload) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        continuation.yield(.init(jobID: jobID, sequence: sequence, payload: payload)); sequence += 1
    }
    func finish(_ payload: TransformationEventPayload) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.yield(.init(jobID: jobID, sequence: sequence, payload: payload))
        continuation.finish()
    }
}

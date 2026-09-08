// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One heavy job per engine, including while an external process is awaited.
actor JobGate {
    private var active = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if !active { active = true; continuation.resume() }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
    }
    func release() {
        if waiters.isEmpty { active = false }
        else { waiters.removeFirst().1.resume() }
    }
}

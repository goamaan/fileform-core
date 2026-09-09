// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A separately bounded preview lane so thumbnails cannot launch an unbounded
/// number of parsers. Callers cancel superseded requests through their Swift task.
public actor NativePreviewService {
    private let client: NativeWorkerClient
    private let lanes = [JobGate(), JobGate()]
    private var nextLane = 0
    public init(executable: URL) { client = NativeWorkerClient(executable: executable) }
    public func preview(_ input: URL, maximumDimension: Int = 1024, pageIndex: Int? = nil) async throws -> NativePreview {
        let lane = lanes[nextLane]; nextLane = (nextLane + 1) % lanes.count
        try await lane.acquire()
        do {
            let preview = try await client.preview(input, maximumDimension: maximumDimension, pageIndex: pageIndex)
            await lane.release(); return preview
        } catch { await lane.release(); throw error }
    }
}

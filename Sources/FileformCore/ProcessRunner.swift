// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import FileformDomain

struct ProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var status: Int32? { lock.lock(); defer { lock.unlock() }; return value }
    func finish(_ status: Int32) { lock.lock(); value = status; lock.unlock() }
}

enum ProcessRunner {
    /// Redirecting both streams to bounded scratch files avoids pipe-buffer
    /// deadlocks. Each invocation owns and removes its scratch directory.
    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 60, monitoredOutput: URL? = nil, maximumOutputBytes: Int64 = 512 * 1024 * 1024) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("fileform-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stdoutURL = scratch.appendingPathComponent("stdout")
        let stderrURL = scratch.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        let completion = ProcessCompletion()
        process.terminationHandler = { completion.finish($0.terminationStatus) }
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        process.currentDirectoryURL = scratch
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": scratch.path,
                               "AV_LOG_FORCE_NOCOLOR": "1", "LC_ALL": "C"]
        do { try process.run() }
        catch { throw FileformError(.engineUnavailable, "The media engine could not start. Reinstall or rebuild its engine pack.") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        do {
            while completion.status == nil {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw FileformError(.resourceLimit, "The media engine exceeded its time limit.") }
                if let monitoredOutput, let size = try? monitoredOutput.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) > maximumOutputBytes { throw FileformError(.resourceLimit, "The engine exceeded its output size limit.") }
                for url in [stdoutURL, stderrURL] {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= 16 * 1024 * 1024 else { throw FileformError(.resourceLimit, "The media engine exceeded its diagnostic output limit.") }
                }
                try await Task.sleep(for: .milliseconds(40))
            }
        } catch {
            // Await actual termination before a caller deletes any candidate file.
            if process.isRunning { process.terminate() }
            let grace = ContinuousClock.now.advanced(by: .seconds(1))
            while completion.status == nil && ContinuousClock.now < grace {
                // A detached sleep remains usable after the parent was cancelled.
                await Task.detached { try? await Task.sleep(for: .milliseconds(25)) }.value
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while completion.status == nil {
                await Task.detached { try? await Task.sleep(for: .milliseconds(25)) }.value
            }
            throw error
        }
        try Task.checkCancellation()
        for url in [stdoutURL, stderrURL] {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 16 * 1024 * 1024 else { throw FileformError(.resourceLimit, "The media engine exceeded its diagnostic output limit.") }
        }
        return .init(stdout: try Data(contentsOf: stdoutURL), stderr: try Data(contentsOf: stderrURL), status: completion.status ?? -1)
    }
}

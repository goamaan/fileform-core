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
    // URL.resourceValues may cache the size from an earlier poll. Always stat
    // growing outputs, including after process completion, before reading them.
    private static func fileSize(_ url: URL) throws -> Int64 {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &value) }) == 0,
              value.st_mode & S_IFMT == S_IFREG else { throw FileformError(.ioFailure, "Could not inspect engine output staging.") }
        return value.st_size
    }

    /// Redirecting both streams to bounded scratch files avoids pipe-buffer
    /// deadlocks. Each invocation owns and removes its scratch directory.
    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 60, monitoredOutput: URL? = nil, maximumOutputBytes: Int64 = 512 * 1024 * 1024, stdoutFile: URL? = nil, maximumStdoutBytes: Int64 = 16 * 1024 * 1024) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("fileform-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard maximumStdoutBytes > 0, maximumStdoutBytes <= 512 * 1024 * 1024 else { throw FileformError(.invalidRequest, "Invalid process output bound.") }
        let stdoutURL = stdoutFile ?? scratch.appendingPathComponent("stdout")
        let stderrURL = scratch.appendingPathComponent("stderr")
        let stdoutDescriptor = open(stdoutURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard stdoutDescriptor >= 0 else { throw FileformError(.ioFailure, "Could not create engine output staging.") }
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = FileHandle(fileDescriptor: stdoutDescriptor, closeOnDealloc: true)
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
                if let monitoredOutput, let size = try? fileSize(monitoredOutput), size > maximumOutputBytes { throw FileformError(.resourceLimit, "The engine exceeded its output size limit.") }
                for url in [stdoutURL, stderrURL] {
                    let size = try fileSize(url)
                    guard size <= (url == stdoutURL ? maximumStdoutBytes : 16 * 1024 * 1024) else { throw FileformError(.resourceLimit, "The media engine exceeded its diagnostic output limit.") }
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
            let size = try fileSize(url)
            guard size <= (url == stdoutURL ? maximumStdoutBytes : 16 * 1024 * 1024) else { throw FileformError(.resourceLimit, "The media engine exceeded its diagnostic output limit.") }
        }
        if let monitoredOutput, let size = try? fileSize(monitoredOutput), size > maximumOutputBytes { throw FileformError(.resourceLimit, "The engine exceeded its output size limit.") }
        return .init(stdout: stdoutFile == nil ? try Data(contentsOf: stdoutURL) : Data(), stderr: try Data(contentsOf: stderrURL), status: completion.status ?? -1)
    }
}

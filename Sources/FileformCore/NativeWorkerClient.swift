// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import FileformDomain

public struct NativePreview: Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
    public let identity: FileIdentity
}

/// Each request owns a short-lived process group and scratch directory. The
/// executable URL is coordinator configuration, never part of an untrusted plan.
public struct NativeWorkerClient: Sendable {
    public let executable: URL
    public let timeout: TimeInterval
    public init(executable: URL, timeout: TimeInterval = 30) { self.executable = executable; self.timeout = timeout }

    public func inspect(_ input: URL) async throws -> Inspection {
        let result = try await perform(input: input, previewDimension: nil, pageIndex: nil)
        guard case .inspection(let value) = result.response.payload, value.assetID == "source",
              value.identity == result.identity, [.image, .pdf].contains(value.family) else {
            throw FileformError(.verificationFailed, "The worker returned an invalid source inspection.")
        }
        return value.inspection(rebindingTo: input.standardizedFileURL)
    }
    public func preview(_ input: URL, maximumDimension: Int = 1024, pageIndex: Int? = nil) async throws -> NativePreview {
        let result = try await perform(input: input, previewDimension: maximumDimension, pageIndex: pageIndex)
        guard case .preview(let metadata) = result.response.payload, let bytes = result.preview,
              Int64(bytes.count) == metadata.bytes, metadata.width <= maximumDimension, metadata.height <= maximumDimension else {
            throw FileformError(.verificationFailed, "The worker returned an invalid preview.")
        }
        return .init(png: bytes, width: metadata.width, height: metadata.height, identity: result.identity)
    }

    public func exportPreview(_ input: URL, destination: URL, maximumDimension: Int = 1024,
                              pageIndex: Int? = nil) async throws -> VerifiedResult {
        let artifact = try await preview(input, maximumDimension: maximumDimension, pageIndex: pageIndex)
        guard try FileSafety.identity(input) == artifact.identity else { throw FileformError(.inputChanged, "Source changed before preview publication.") }
        let transaction = try OutputTransaction(destination: destination, input: input, collisionPolicy: .fail)
        defer { transaction.cleanup() }
        let candidate = transaction.candidate(0, format: .png)
        try artifact.png.write(to: candidate, options: .withoutOverwriting)
        try Task.checkCancellation()
        let output = try transaction.commit(candidate)
        return .init(status: .succeeded, input: input, output: output, inputBytes: artifact.identity.bytes,
                     outputBytes: Int64(artifact.png.count), format: .png,
                     warnings: ["This is a bounded sRGB preview, not a full-resolution conversion."], attempts: 1)
    }

    private struct Reply: Sendable {
        let response: WorkerResponse
        let identity: FileIdentity
        let preview: Data?
    }
    private func perform(input: URL, previewDimension: Int?, pageIndex: Int?) async throws -> Reply {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { throw FileformError(.invalidRequest, "Invalid worker timeout.") }
        let input = input.standardizedFileURL
        let identity = try FileSafety.identity(input)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(".fileform-worker-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = open(input.resolvingSymlinksInPath().path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard source >= 0 else { throw FileformError(.ioFailure, "Could not open the selected source for the worker.") }
        defer { close(source) }
        var opened = stat()
        guard fstat(source, &opened) == 0, opened.st_dev == identity.device, opened.st_ino == identity.inode,
              opened.st_size == identity.bytes, Int64(opened.st_mtimespec.tv_sec) == identity.modifiedSeconds,
              Int64(opened.st_mtimespec.tv_nsec) == identity.modifiedNanoseconds else {
            throw FileformError(.inputChanged, "The source changed while opening its worker handle.")
        }
        let outputURL = scratch.appendingPathComponent("preview.png")
        let output = open(outputURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw FileformError(.ioFailure, "Could not create worker output staging.") }
        defer { close(output) }
        let operation: WorkerOperation = previewDimension.map {
            .preview(asset: .init(assetID: "source", descriptor: 3), outputDescriptor: 4, maximumDimension: $0, pageIndex: pageIndex)
        } ?? .inspect(asset: .init(assetID: "source", descriptor: 3))
        let request = try WorkerRequest(operation: operation)
        let handshake = try WorkerRequest(operation: .handshake)
        var message = try WorkerFrameCodec.encode(handshake)
        message.append(try WorkerFrameCodec.encode(request))
        let pipe = try WorkerProcess(executable: executable, source: source, output: output, scratch: scratch, message: message)
        let data = try await withTaskCancellationHandler {
            try await pipe.collect(timeout: timeout)
        } onCancel: { pipe.stop() }
        let responses: [WorkerResponse]
        do {
            var decoder = try WorkerFrameDecoder<WorkerResponse>()
            responses = try decoder.append(data)
            try decoder.finish()
        } catch { throw FileformError(.engineFailed, "The native worker returned an invalid protocol message.") }
        guard responses.count == 2, responses[0].id == handshake.id,
              case .handshake(let version) = responses[0].payload, version == WorkerProtocol.version,
              responses[1].id == request.id else {
            throw FileformError(.engineFailed, "The worker protocol handshake or request identity did not match.")
        }
        if case .failure(let code) = responses[1].payload {
            let error: FileformError.Code = switch code {
            case .unsupportedInput: .unsupported; case .invalidInput: .invalidRequest
            case .permissionDenied: .ioFailure; case .resourceLimit: .resourceLimit
            case .cancelled: .cancelled; case .internalFailure: .engineFailed
            }
            throw FileformError(error, "The native worker could not process this file (\(code.rawValue)).")
        }
        guard try FileSafety.identity(input) == identity else { throw FileformError(.inputChanged, "The source changed during worker processing.") }
        let preview: Data?
        if previewDimension != nil {
            let handle = try FileHandle(forReadingFrom: outputURL); defer { try? handle.close() }
            let data = try handle.read(upToCount: 80 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 80 * 1024 * 1024 else { throw FileformError(.resourceLimit, "Worker preview exceeded its size limit.") }
            preview = data
        } else { preview = nil }
        return .init(response: responses[1], identity: identity, preview: preview)
    }
}

/// All process-lifetime mutations are locked, including waitpid and group signals.
private final class WorkerProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var reaped = false
    private var exitStatus: Int32 = 0
    private let stdout: Int32
    init(executable: URL, source: Int32, output: Int32, scratch: URL, message: Data) throws {
        var inputPipe = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&inputPipe) == 0 else { throw FileformError(.ioFailure, "Could not open worker input pipe.") }
        guard pipe(&outputPipe) == 0 else {
            close(inputPipe[0]); close(inputPipe[1])
            throw FileformError(.ioFailure, "Could not open worker output pipe.")
        }
        let stdin = inputPipe[0], stdout = outputPipe[0]
        let stderr = open("/dev/null", O_WRONLY | O_CLOEXEC)
        defer { close(stdin); close(inputPipe[1]); close(outputPipe[1]); if stderr >= 0 { close(stderr) } }
        // Two small typed requests fit in the pipe before launch. No arbitrary
        // arguments or unbounded serialized data can block this synchronous write.
        guard stderr >= 0, message.count <= 4096,
              message.withUnsafeBytes({ write(inputPipe[1], $0.baseAddress, $0.count) }) == message.count,
              fcntl(stdout, F_SETFL, O_NONBLOCK) == 0 else {
            close(stdout); throw FileformError(.ioFailure, "Could not prepare bounded worker pipes.")
        }
        // Duplicates above stdio/worker slots avoid file-action descriptor cycles.
        let originals = [stdin, outputPipe[1], stderr, source, output]
        let descriptors = originals.map { fcntl($0, F_DUPFD_CLOEXEC, 20) }
        defer { for fd in descriptors where fd >= 0 { close(fd) } }
        guard descriptors.allSatisfy({ $0 >= 0 }) else { close(stdout); throw FileformError(.ioFailure, "Could not transfer worker file handles.") }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(stdout); throw FileformError(.engineFailed, "Could not initialize worker launch.")
        }
        guard posix_spawnattr_init(&attributes) == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            close(stdout); throw FileformError(.engineFailed, "Could not initialize worker attributes.")
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        var error: Int32 = 0
        for (slot, fd) in descriptors.enumerated() {
            let value = posix_spawn_file_actions_adddup2(&actions, fd, Int32(slot))
            if value != 0 { error = value }
        }
        error |= posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        error |= posix_spawnattr_setpgroup(&attributes, 0)
        guard error == 0 else { close(stdout); throw FileformError(.engineFailed, "Could not configure isolated worker descriptors.") }
        let arguments: [UnsafeMutablePointer<CChar>?] = [executable.path].map { $0.withCString { strdup($0) } } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = ["PATH=/usr/bin:/bin", "TMPDIR=\(scratch.path)/"].map { $0.withCString { strdup($0) } } + [nil]
        defer { for p in arguments + environment { if let p { free(p) } } }
        var spawnedPID: pid_t = 0
        error = arguments.withUnsafeBufferPointer { argv in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&spawnedPID, executable.path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard error == 0 else { close(stdout); throw FileformError(.engineUnavailable, "The native worker could not be launched.") }
        self.pid = spawnedPID; self.stdout = stdout
    }
    deinit { stop(); close(stdout) }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        guard !reaped, pid > 0 else { return }
        kill(-pid, SIGKILL)
    }
    private func poll() -> (done: Bool, status: Int32, cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !reaped {
            var info = siginfo_t()
            // Keep the leader PID reserved until its whole process group has
            // received termination, even if a descendant outlived the leader.
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if result == 0, info.si_pid == pid {
                kill(-pid, SIGKILL)
                var waited: pid_t
                repeat { waited = waitpid(pid, &exitStatus, 0) } while waited < 0 && errno == EINTR
                reaped = true
                if waited != pid { exitStatus = -1 }
            } else if result < 0, errno == ECHILD {
                // Never signal a PID that another owner has already reaped.
                reaped = true; exitStatus = -1
            }
        }
        return (reaped, exitStatus, cancelled)
    }
    func collect(timeout: TimeInterval) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var tooLarge = false
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        func drain() {
            while true {
                let count = read(stdout, &buffer, buffer.count)
                if count <= 0 { break }
                if response.count + count > 2 * WorkerProtocol.maximumFrameBytes + 8 { tooLarge = true; stop(); break }
                response.append(contentsOf: buffer.prefix(count))
            }
        }
        while true {
            drain()
            if clock.now >= deadline { stop() }
            if Task.isCancelled { stop() }
            let state = poll()
            if state.done {
                drain()
                if Task.isCancelled || state.cancelled && !tooLarge && clock.now < deadline { throw CancellationError() }
                guard !tooLarge else { throw FileformError(.resourceLimit, "Worker response exceeded its bounded protocol size.") }
                guard clock.now < deadline else { throw FileformError(.engineFailed, "The native worker timed out.") }
                guard state.status == 0 else { throw FileformError(.engineFailed, "The native worker exited unexpectedly.") }
                return response
            }
            // Cancellation must still wait for reaping before the caller removes scratch.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { continuation.resume() }
            }
        }
    }
}

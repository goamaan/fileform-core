// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import FileformDomain
import FileformCore

@main
struct WorkerCommand {
    static func main() {
        do {
            guard CommandLine.arguments.count == 1 else { throw WorkerProtocolError.invalidRequest }
            try installLimits()
            let handshake = try readRequest()
            guard case .handshake = handshake.operation else { throw WorkerProtocolError.invalidRequest }
            try writeResponse(NativeWorkerOperations.execute(handshake))
            let request = try readRequest()
            guard request.id != handshake.id else { throw WorkerProtocolError.invalidRequest }
            if case .handshake = request.operation { throw WorkerProtocolError.invalidRequest }
            try writeResponse(NativeWorkerOperations.execute(request))
            exit(0)
        } catch {
            // Never export a parser's raw diagnostics or personal paths.
            let message = Data("Worker protocol or resource failure.\n".utf8)
            try? FileHandle.standardError.write(contentsOf: message)
            exit(2)
        }
    }

    private static func installLimits() throws {
        for (resource, ceiling) in [(RLIMIT_CORE, rlim_t(0)), (RLIMIT_CPU, rlim_t(60)),
                                    (RLIMIT_FSIZE, rlim_t(NativeWorkerOperations.maximumInputBytes))] {
            var existing = rlimit()
            guard getrlimit(resource, &existing) == 0 else { throw WorkerProtocolError.invalidRequest }
            let bounded = min(existing.rlim_max, ceiling)
            var limits = rlimit(rlim_cur: min(existing.rlim_cur, bounded), rlim_max: bounded)
            guard setrlimit(resource, &limits) == 0 else { throw WorkerProtocolError.invalidRequest }
        }
    }

    private static func readRequest() throws -> WorkerRequest {
        // The header is checked before body allocation/read. Reading exactly one
        // frame preserves the second message even if the pipe coalesces writes.
        let header = try readExactly(4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0 else { throw WorkerProtocolError.emptyFrame }
        guard size <= UInt32(WorkerProtocol.maximumFrameBytes) else { throw WorkerProtocolError.oversizedFrame }
        var decoder = try WorkerFrameDecoder<WorkerRequest>()
        _ = try decoder.append(header)
        var remaining = Int(size)
        var result: WorkerRequest?
        while remaining > 0 {
            let bytes = try readExactly(min(remaining, 64 * 1024))
            remaining -= bytes.count
            if let request = try decoder.append(bytes).first { result = request }
        }
        try decoder.finish()
        guard let result else { throw WorkerProtocolError.malformedMessage }
        return result
    }

    private static func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try FileHandle.standardInput.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw WorkerProtocolError.truncatedFrame
            }
            data.append(chunk)
        }
        return data
    }

    private static func writeResponse(_ response: WorkerResponse) throws {
        try FileHandle.standardOutput.write(contentsOf: WorkerFrameCodec.encode(response))
    }
}

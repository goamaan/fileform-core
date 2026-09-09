// SPDX-License-Identifier: Apache-2.0
import Foundation
import ArgumentParser
import FileformDomain
import FileformCore

struct FetchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fetch", abstract: "Look up and save verified direct media URLs.", subcommands: [FetchLookup.self, FetchSave.self])
}
struct FetchLookup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lookup", abstract: "Contact a direct source for response metadata; no media is saved.")
    @Argument(help: "HTTP(S) source without embedded username/password.") var url: String
    @Option(help: "Maximum permitted source bytes.") var maxBytes: Int64 = 512 * 1024 * 1024
    @Flag(help: "Emit structured errors.") var json = false
    mutating func run() async throws {
        do {
            guard let source = URL(string: url) else { throw FileformError(.invalidRequest, "Enter an HTTP(S) source URL.") }
            let policy = try HTTPAcquisitionPolicy(maximumBytes: maxBytes, allowInsecureHTTP: source.scheme?.lowercased() == "http")
            try await cancellable {
                let metadata = try await DirectHTTPClient().inspect(source, policy: policy)
                try emit(FetchSourceSnapshot(requestedURL: source, resolvedURL: metadata.url, contentType: metadata.contentType,
                    expectedBytes: metadata.expectedBytes, entityTag: metadata.entityTag, lastModified: metadata.lastModified))
            }
        } catch { try fail(error, json: json) }
    }
}
struct FetchSave: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "save", abstract: "Save original direct-media bytes after complete verification; no format conversion.")
    @Argument(help: "HTTP(S) source without embedded username/password.") var url: String
    @Option(name: .customLong("to"), help: "Expected source type: mp4, mov, m4a, wav, flac or mp3. A mismatch fails.") var format: OutputFormat
    @Option(help: "New local output path.") var output: String
    @Option(help: "Maximum source bytes, enforced while receiving.") var maxBytes: Int64 = 512 * 1024 * 1024
    @Option(help: "Existing-name policy: fail or rename.") var collision: CollisionPolicy = .fail
    @Option(help: "Verified media pack directory; FILEFORM_MEDIA_PACK is also accepted.") var mediaPack: String?
    @Flag(help: "Look up the source and emit a plan without downloading or publishing media.") var dryRun = false
    @Flag(help: "Emit structured errors.") var json = false
    mutating func run() async throws {
        do {
            guard let source = URL(string: url) else { throw FileformError(.invalidRequest, "Enter an HTTP(S) source URL.") }
            let request = try TransformationRequest(assets: [], operation: .fetch(url: source, maximumBytes: maxBytes),
                output: .init(destination: URL(fileURLWithPath: output), format: format), collisionPolicy: collision)
            let engine = makeEngine(mediaPack), dryRun = dryRun
            let status = FetchProgressStatus()
            try await cancellable {
                let plan = try await engine.plan(request)
                if dryRun { try emit(plan); return }
                for warning in plan.warnings { diagnostic(warning) }
                try emit(await engine.run(plan) { if let message = status.message($0) { diagnostic(message) } })
            }
        } catch { try fail(error, json: json) }
    }
}

private final class FetchProgressStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var previous = ""
    func message(_ event: ProgressEvent) -> String? {
        lock.lock(); defer { lock.unlock() }
        let text = event.phase == .preparing
            ? "downloading" + (event.fraction.map { " \(Int(min(1, max(0, $0)) * 100))%" } ?? "")
            : event.phase.rawValue
        guard text != previous else { return nil }
        previous = text; return text
    }
}

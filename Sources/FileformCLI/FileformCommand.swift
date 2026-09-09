// SPDX-License-Identifier: Apache-2.0
import Foundation
import ArgumentParser
import FileformCore
import FileformDomain

extension OutputFormat: ExpressibleByArgument {}
extension CollisionPolicy: ExpressibleByArgument {}
extension AlphaBackground: ExpressibleByArgument {}

@main
struct FileformCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fileform", abstract: "Convert files locally and verify the result.",
        version: "0.1.0-dev", subcommands: [Inspect.self, Capabilities.self, Convert.self, Compress.self, Fit.self, Transform.self, Setup.self, Preview.self])
}

struct Inspect: AsyncParsableCommand {
    @Option(help: "Use this native worker executable for isolated image/PDF inspection.") var worker: String?
    static let configuration = CommandConfiguration(abstract: "Inspect a local file's content.")
    @Argument(help: "Input file.") var input: String
    @Flag(help: "Write a structured report to stdout.") var json = false
    @Option(help: "Media pack directory; also accepts FILEFORM_MEDIA_PACK.") var mediaPack: String?
    mutating func run() async throws {
        do {
            let value: Inspection
            if let worker {
                let client = NativeWorkerClient(executable: URL(fileURLWithPath: worker))
                let url = URL(fileURLWithPath: input)
                value = try await cancellable { try await client.inspect(url) }
            } else { value = try await makeEngine(mediaPack).inspect(URL(fileURLWithPath: input)) }
            if json { try emit(value) }
            else {
                print("\(value.input.lastPathComponent): \(value.detectedType), \(value.identity.bytes) bytes")
                if let width = value.width, let height = value.height { print("\(width) × \(height)") }
                for warning in value.warnings { diagnostic(warning) }
            }
        } catch { try fail(error, json: json) }
    }
}

struct Capabilities: AsyncParsableCommand {
    @Flag(help: "Emit the versioned operation inventory instead of the legacy list.") var inventory = false
    static let configuration = CommandConfiguration(abstract: "List implemented output capabilities.")
    @Option(help: "Restrict outputs to an inspected input file.") var input: String?
    @Flag(help: "Write a structured report to stdout.") var json = false
    @Option(help: "Media pack directory; also accepts FILEFORM_MEDIA_PACK.") var mediaPack: String?
    mutating func run() async throws {
        do {
            let engine = makeEngine(mediaPack)
            let inspection: Inspection?
            if let input { inspection = try await engine.inspect(URL(fileURLWithPath: input)) } else { inspection = nil }
            if inventory { try emit(await engine.capabilityInventory(for: inspection)); return }
            let values = await engine.capabilities(for: inspection)
            if json { try emit(values) }
            else { for value in values { print("\(value.format.title)\t\(value.available ? "available" : "unavailable")\t\(value.engine)") } }
        } catch { try fail(error, json: json) }
    }
}

struct JobArguments: ParsableArguments {
    @Argument(help: "Input file. Originals are never overwritten.") var input: String
    @Option(name: .customLong("to"), help: "Output format.") var format: OutputFormat
    @Option(help: "Output file. Defaults to <name>-converted.<extension> beside the input.") var output: String?
    @Option(help: "Collision handling: fail or rename. Never replaces existing files.") var collision: CollisionPolicy = .fail
    @Option(help: "Lossy image quality, from 0.05 to 1.") var quality: Double = 0.82
    @Option(help: "Minimum permitted lossy image quality for fit-size.") var minimumQuality: Double = 0.35
    @Option(help: "Explicit maximum longest edge in pixels; never upscales.") var maxDimension: Int?
    @Option(help: "Explicit background for transparency removal: white or black.") var background: AlphaBackground?
    @Option(help: "Minimum video bitrate for fit-size, in bits per second.") var minimumVideoBitrate: Int = 150_000
    @Option(help: "Explicit one-based PDF page to export. Text extraction otherwise reads all pages.") var page: Int?
    @Option(help: "Media pack directory; also accepts FILEFORM_MEDIA_PACK.") var mediaPack: String?
    @Flag(help: "Inspect and plan without encoding or creating output files.") var dryRun = false
    @Flag(help: "Write one terminal JSON report to stdout; progress stays on stderr.") var json = false

    func execute(goal: ConversionGoal, maximumBytes: Int64? = nil) async throws {
        do {
            let inputURL = URL(fileURLWithPath: input).standardizedFileURL
            let destination = output.map { URL(fileURLWithPath: $0) } ?? inputURL.deletingLastPathComponent()
                .appendingPathComponent("\(inputURL.deletingPathExtension().lastPathComponent)-converted.\(format.fileExtension)")
            let request = ConversionRequest(input: inputURL, destination: destination, format: format, goal: goal,
                                            options: .init(quality: quality, minimumQuality: minimumQuality,
                                                           maxDimension: maxDimension, maximumBytes: maximumBytes, background: background,
                                                           minimumVideoBitrate: minimumVideoBitrate, pageNumber: page),
                                            collisionPolicy: collision)
            let engine = makeEngine(mediaPack)
            let plan = try await engine.plan(request)
            if dryRun { try emit(plan); return }
            for warning in plan.warnings { diagnostic(warning) }
            let result = try await cancellable {
                try await engine.run(plan) { event in diagnostic(event.phase.rawValue) }
            }
            if json { try emit(result) }
            else if let output = result.output { print("Saved \(output.path) (\(result.outputBytes ?? 0) bytes)") }
            else { print("\(result.status.rawValue): original retained") }
        } catch { try fail(error, json: json) }
    }
}

struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Convert to a chosen format.")
    @OptionGroup var job: JobArguments
    mutating func run() async throws { try await job.execute(goal: .convert) }
}
struct Compress: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Keep a new output only if it is smaller.")
    @OptionGroup var job: JobArguments
    mutating func run() async throws { try await job.execute(goal: .compress) }
}
struct Fit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Produce a complete output at or below an exact byte limit.")
    @OptionGroup var job: JobArguments
    @Option(help: "Positive integer byte limit; 1 MB = 1000000 bytes.") var maxBytes: Int64
    mutating func run() async throws { try await job.execute(goal: .fit, maximumBytes: maxBytes) }
}

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value)); FileHandle.standardOutput.write(Data("\n".utf8))
}
func diagnostic(_ value: String) { FileHandle.standardError.write(Data((value + "\n").utf8)) }
func makeEngine(_ path: String?) -> ConversionEngine {
    let path = path ?? ProcessInfo.processInfo.environment["FILEFORM_MEDIA_PACK"]
    if let path { return ConversionEngine(mediaPack: URL(fileURLWithPath: path)) }
    let adjacent = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MediaPack")
    let available = adjacent.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) ? $0 : nil }
    return ConversionEngine(mediaPack: available)
}
func fail(_ error: Error, json: Bool) throws -> Never {
    let error = error as? FileformError ?? (error is CancellationError ? FileformError(.cancelled, "Conversion cancelled; owned partial outputs removed.") : FileformError(.ioFailure, error.localizedDescription))
    if json { try emit(error) } else { diagnostic("\(error.code.rawValue): \(error.message)") }
    throw ExitCode(error.exitCode)
}

func cancellable<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    signal(SIGINT, SIG_IGN)
    let task = Task { try await operation() }
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { task.cancel() }
    source.resume()
    defer { source.cancel(); signal(SIGINT, SIG_DFL) }
    return try await task.value
}

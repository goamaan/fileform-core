// SPDX-License-Identifier: Apache-2.0
import Foundation
import ArgumentParser
import FileformDomain
import FileformCore

extension TrimMode: ExpressibleByArgument {}

struct MediaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "media", abstract: "Edit local audio and video with measured timing.",
                                                     subcommands: [MediaTrim.self])
}

struct MediaTrim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trim", abstract: "Trim an exact frame/sample interval, or copy an eligible snapped range.")
    @Argument(help: "Local recording. The original is never overwritten.") var input: String
    @Option(name: .customLong("to"), help: "MP4/MOV video or M4A/WAV/FLAC audio output. MP3 is not installed.") var format: OutputFormat
    @Option(help: "Inclusive source start: decimal seconds (up to 9 places) or ticks/timescale.") var start: String
    @Option(help: "Exclusive source end: decimal seconds or ticks/timescale.") var end: String
    @Option(help: "exact selects frame/sample boundaries; copy snaps outward to eligible keyframe/packet boundaries.") var mode: TrimMode = .exact
    @Option(help: "Zero-based ordinal among source audio streams; required when there are multiple audio tracks.") var audioStream: Int?
    @Option(help: "New output path; defaults to <name>-trimmed.<extension>.") var output: String?
    @Option(help: "Collision policy: fail or rename. Source aliases are rejected.") var collision: CollisionPolicy = .fail
    @Option(help: "Verified media engine pack directory; FILEFORM_MEDIA_PACK is also accepted.") var mediaPack: String?
    @Flag(help: "Emit the measured plan, including snapped bounds, without writing an output.") var dryRun = false
    @Flag(help: "Emit structured errors and result measurements.") var json = false

    mutating func run() async throws {
        do {
            let input = URL(fileURLWithPath: input).standardizedFileURL
            let destination = output.map { URL(fileURLWithPath: $0) } ?? input.deletingLastPathComponent()
                .appendingPathComponent("\(input.deletingPathExtension().lastPathComponent)-trimmed.\(format.fileExtension)")
            let interval = MediaInterval(start: try Self.time(start), end: try Self.time(end))
            let request = try TransformationRequest(assets: [.init(id: "source", url: input)],
                operation: .mediaTrim(interval: interval, mode: mode, audioStream: audioStream),
                output: .init(destination: destination, format: format), collisionPolicy: collision)
            let engine = makeEngine(mediaPack), dryRun = dryRun
            try await cancellable {
                let plan = try await engine.plan(request)
                if dryRun { try emit(plan); return }
                for warning in plan.warnings { diagnostic(warning) }
                try emit(await engine.run(plan) { diagnostic($0.phase.rawValue) })
            }
        } catch { try fail(error, json: json) }
    }

    private static func time(_ text: String) throws -> MediaTime {
        guard text.utf8.count <= 64 else { throw FileformError(.invalidRequest, "The time value is too long.") }
        let rational = text.split(separator: "/", omittingEmptySubsequences: false)
        if rational.count == 2, let ticks = Int64(rational[0]), let scale = Int32(rational[1]) {
            let time = MediaTime(ticks: ticks, timescale: scale)
            try time.validate()
            return time
        }
        guard rational.count == 1, text.range(of: #"^[0-9]+(?:\.[0-9]{1,9})?$"#, options: .regularExpression) != nil else {
            throw FileformError(.invalidRequest, "Use nonnegative decimal seconds or integer ticks/positive-timescale for each time.")
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let decimalPlaces = parts.count == 2 ? parts[1].count : 0
        var scale: Int32 = 1
        for _ in 0..<decimalPlaces { scale *= 10 }
        guard let ticks = Int64(parts.joined()) else { throw FileformError(.invalidRequest, "The time value is out of range.") }
        return .init(ticks: ticks, timescale: scale)
    }
}

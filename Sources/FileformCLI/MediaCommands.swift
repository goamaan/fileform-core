// SPDX-License-Identifier: Apache-2.0
import Foundation
import ArgumentParser
import FileformDomain
import FileformCore

extension TrimMode: ExpressibleByArgument {}

struct MediaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "media", abstract: "Edit local audio and video with measured timing.",
                                                     subcommands: [MediaTrim.self, MediaInspect.self, MediaWaveformCommand.self, MediaPreviewCommand.self])
}

struct MediaTrim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trim", abstract: "Trim an exact frame/sample interval, or copy an eligible snapped range.")
    @Argument(help: "Local recording. The original is never overwritten.") var input: String
    @Option(name: .customLong("to"), help: "MP4/MOV video or M4A/WAV/FLAC audio output. MP3 is not installed.") var format: OutputFormat
    @Option(help: "Inclusive source start: decimal seconds (up to 9 places) or ticks/timescale.") var start: String
    @Option(help: "Exclusive source end: decimal seconds or ticks/timescale.") var end: String
    @Option(help: "exact selects frame/sample boundaries; copy snaps outward to eligible keyframe/packet boundaries.") var mode: TrimMode = .exact
    @Option(help: "Zero-based ordinal among source audio streams; required when there are multiple audio tracks.") var audioStream: Int?
    @Flag(help: "Explicitly omit all audio from a video output; cannot combine with --audio-stream.") var mute = false
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
                operation: .mediaTrim(interval: interval, mode: mode, audioStream: audioStream, muteAudio: mute),
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

    static func time(_ text: String) throws -> MediaTime {
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

struct MediaPreviewArguments: ParsableArguments {
    @Argument(help: "Local recording.") var input: String
    @Option(help: "Verified media pack directory; FILEFORM_MEDIA_PACK is also accepted.") var mediaPack: String?
    @Flag(help: "Emit structured errors.") var json = false
    func service() throws -> MediaPreviewService {
        guard let path = mediaPack ?? ProcessInfo.processInfo.environment["FILEFORM_MEDIA_PACK"] else {
            throw FileformError(.engineUnavailable, "Provide --media-pack or FILEFORM_MEDIA_PACK for media preview operations.")
        }
        return MediaPreviewService(mediaPack: URL(fileURLWithPath: path))
    }
}
struct MediaInspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Measure the recording's exact frame/sample timeline and audio tracks.")
    @OptionGroup var source: MediaPreviewArguments
    mutating func run() async throws {
        do {
            let service = try source.service(), input = URL(fileURLWithPath: source.input)
            try await cancellable { try emit(await service.inspect(input)) }
        } catch { try fail(error, json: source.json) }
    }
}
struct MediaWaveformCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "waveform", abstract: "Emit measured per-channel waveform envelopes with exact sample intervals.")
    @OptionGroup var source: MediaPreviewArguments
    @Option(help: "Selected audio-track ordinal; required for multitrack recordings.") var audioStream: Int?
    @Option(help: "Maximum waveform bucket count, from 16 to 4096.") var bins = 512
    mutating func run() async throws {
        do {
            let service = try source.service(), input = URL(fileURLWithPath: source.input), audio = audioStream, bins = bins
            try await cancellable { try emit(await service.waveform(for: service.inspect(input), audioStream: audio, bins: bins)) }
        } catch { try fail(error, json: source.json) }
    }
}
struct MediaPreviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "preview", abstract: "Export a verified normalized playback file or a measured video poster.")
    @OptionGroup var source: MediaPreviewArguments
    @Option(help: "New output path. Playback uses MP4 for video and WAV for audio; a poster uses PNG.") var output: String
    @Option(help: "Audio-track ordinal for playback preview.") var audioStream: Int?
    @Flag(help: "Omit audio from a video playback preview.") var mute = false
    @Option(help: "Optional poster time in decimal seconds or ticks/timescale. Otherwise create a playback preview.") var posterTime: String?
    @Option(help: "Maximum picture dimension; 64–1920 for playback, 1–4096 for posters.") var maxDimension = 1280
    mutating func run() async throws {
        do {
            guard posterTime == nil || (audioStream == nil && !mute) else { throw FileformError(.invalidRequest, "Poster export does not select audio.") }
            let service = try source.service(), input = URL(fileURLWithPath: source.input), output = URL(fileURLWithPath: output)
            let time = try posterTime.map(MediaTrim.time), audio = audioStream, mute = mute, size = maxDimension
            try await cancellable {
                let timeline = try await service.inspect(input)
                if let time { try emit(await service.exportPoster(for: timeline, destination: output, at: time, maximumDimension: size)) }
                else { try emit(await service.exportPlaybackPreview(for: timeline, destination: output, audioStream: audio, muteAudio: mute, maximumDimension: size)) }
            }
        } catch { try fail(error, json: source.json) }
    }
}

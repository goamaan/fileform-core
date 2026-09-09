// SPDX-License-Identifier: Apache-2.0
import Foundation
import ImageIO
import FileformDomain

/// Retain this lease for as long as a player is reading its URL. Discard releases
/// only its runtime-owned directory; it never deletes a source or user output.
public final class MediaPlaybackPreview: @unchecked Sendable {
    public let url: URL
    public let identity: FileIdentity
    public let duration: MediaTime
    public let audioStreamIndex: Int?
    public let videoStreamIndex: Int?
    public let warnings: [String]
    private let directory: URL
    private let lock = NSLock()
    private var discarded = false
    init(url: URL, directory: URL, identity: FileIdentity, duration: MediaTime,
         audioStreamIndex: Int?, videoStreamIndex: Int?, warnings: [String]) {
        self.url = url; self.directory = directory; self.identity = identity; self.duration = duration
        self.audioStreamIndex = audioStreamIndex; self.videoStreamIndex = videoStreamIndex; self.warnings = warnings
    }
    public func discard() {
        lock.lock(); defer { lock.unlock() }
        guard !discarded else { return }
        discarded = true
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { discard() }
}

/// Public media helpers run off UI actors through isolated FFmpeg processes.
/// Callers cancel superseded inspection/preview work with normal Task cancellation.
public actor MediaPreviewService {
    private let mediaPack: URL
    private var cached: MediaTimelineReading?
    public init(mediaPack: URL) { self.mediaPack = mediaPack }
    public func inspect(_ input: URL) async throws -> MediaTimeline {
        try await reading(input).timeline
    }
    public func waveform(for timeline: MediaTimeline, audioStream: Int? = nil, bins: Int = 512) async throws -> MediaWaveform {
        guard (16...4096).contains(bins) else { throw FileformError(.invalidRequest, "Choose between 16 and 4096 waveform buckets.") }
        _ = try await checked(timeline)
        let audio = try selectedAudio(timeline, ordinal: audioStream)
        let rate = Int64(audio.sampleRate)
        let duration = audio.duration
        let whole = duration.ticks / Int64(duration.timescale), rest = duration.ticks % Int64(duration.timescale)
        let samples = whole * rate + (rest * rate + Int64(duration.timescale) - 1) / Int64(duration.timescale)
        guard samples > 0, samples <= audio.decodedSamples else { throw FileformError(.unsupported, "Decoded audio does not cover its measured waveform duration.") }
        let perBucket = (samples + Int64(bins) - 1) / Int64(bins)
        guard perBucket * Int64(audio.channels) * 4 <= 128 * 1024 * 1024 else {
            throw FileformError(.resourceLimit, "Choose more waveform buckets for this recording’s sample rate and channel count.")
        }
        let pack = try MediaPack(directory: mediaPack)
        // Float conversion preserves separate channels. Padding is disabled;
        // every returned extremum comes from actual decoded source samples.
        let filter = "aformat=sample_fmts=flt,atrim=end_sample=\(samples),asetpts=N/SR/TB,asetnsamples=n=\(perBucket):p=0,astats=metadata=1:reset=1:measure_perchannel=Min_level+Max_level:measure_overall=Number_of_samples,ametadata=mode=print:file=-"
        let response = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-xerror", "-max_alloc", "268435456", "-protocol_whitelist", "file,pipe", "-threads", "2",
            "-i", timeline.source.path, "-map", "0:\(audio.index)", "-vn", "-sn", "-dn", "-af", filter, "-f", "null", "-"
        ], timeout: 300)
        guard response.status == 0, let text = String(data: response.stdout, encoding: .utf8) else {
            throw FileformError(.engineFailed, "The audio waveform could not be decoded.")
        }
        let buckets = try parseWaveform(text, channels: audio.channels, rate: audio.sampleRate, samples: samples, maximum: bins)
        try verifyIdentity(timeline)
        return .init(source: timeline.source, identity: timeline.identity, duration: duration, audioOrdinal: audio.ordinal,
            audioStreamIndex: audio.index, sampleRate: audio.sampleRate, channels: audio.channels, buckets: buckets)
    }
    public func poster(for timeline: MediaTimeline, at time: MediaTime, maximumDimension: Int = 512) async throws -> MediaPoster {
        guard (1...4096).contains(maximumDimension) else { throw FileformError(.invalidRequest, "Invalid poster dimensions.") }
        let measured = try await checked(timeline)
        guard let video = timeline.video, try time.isBefore(timeline.duration),
              let index = try measured.videoFrameStarts.lastIndex(where: { try !time.isBefore($0) }) else {
            throw FileformError(.invalidRequest, "Choose a time within a measured video timeline.")
        }
        let directory = try scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("poster.png")
        let pack = try MediaPack(directory: mediaPack)
        let filter = "select=eq(n\\,\(index)),scale=\(maximumDimension):\(maximumDimension):force_original_aspect_ratio=decrease"
        let response = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-xerror", "-max_alloc", "268435456", "-protocol_whitelist", "file,pipe", "-threads", "2",
            "-i", timeline.source.path, "-map", "0:\(video.index)", "-an", "-sn", "-dn", "-vf", filter,
            "-frames:v", "1", "-c:v", "png", "-fs", "83886080", output.path
        ], timeout: 120)
        guard response.status == 0 else { throw FileformError(.engineFailed, "The video poster could not be decoded.") }
        let handle = try FileHandle(forReadingFrom: output); defer { try? handle.close() }
        let png = try handle.read(upToCount: 83_886_081) ?? Data()
        guard png.count <= 83_886_080, let image = CGImageSourceCreateWithData(png as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(image, 0, nil), decoded.width <= maximumDimension, decoded.height <= maximumDimension else {
            throw FileformError(.verificationFailed, "The generated video poster failed verification.")
        }
        try verifyIdentity(timeline)
        return .init(png: png, identity: timeline.identity, requestedTime: time, realizedTime: measured.videoFrameStarts[index],
                     width: decoded.width, height: decoded.height)
    }
    public func playbackPreview(for timeline: MediaTimeline, audioStream: Int? = nil, muteAudio: Bool = false,
                                maximumDimension: Int = 1280) async throws -> MediaPlaybackPreview {
        guard (64...1920).contains(maximumDimension), !muteAudio || (timeline.video != nil && audioStream == nil) else {
            throw FileformError(.invalidRequest, "Invalid playback dimensions or audio selection.")
        }
        _ = try await checked(timeline)
        let audio: MediaAudioTrack? = muteAudio || timeline.audioTracks.isEmpty ? nil : try selectedAudio(timeline, ordinal: audioStream)
        let directory = try scratch()
        var transferred = false
        defer { if !transferred { try? FileManager.default.removeItem(at: directory) } }
        let format: OutputFormat = timeline.video == nil ? .wav : .mp4
        var output = directory.appendingPathComponent("playback." + format.fileExtension)
        let engine = ConversionEngine(mediaPack: mediaPack)
        let request = try TransformationRequest(assets: [.init(id: "source", url: timeline.source)],
            operation: .mediaTrim(interval: .init(start: .init(ticks: 0, timescale: 1), end: timeline.duration),
                mode: .exact, audioStream: audio?.ordinal, muteAudio: muteAudio), output: .init(destination: output, format: format))
        let plan = try await engine.plan(request)
        _ = try await engine.run(plan)
        if let video = timeline.video, max(video.displayWidth, video.displayHeight) > maximumDimension {
            let resized = directory.appendingPathComponent("playback-sized.mp4")
            let conversion = ConversionRequest(input: output, destination: resized, format: .mp4,
                options: .init(maxDimension: maximumDimension), collisionPolicy: .fail)
            _ = try await engine.run(engine.plan(conversion))
            try FileManager.default.removeItem(at: output); output = resized
        }
        let pack = try MediaPack(directory: mediaPack)
        let inspected = try await MediaBackend(pack: pack).probe(output)
        guard inspected.audios.count == (audio == nil ? 0 : 1), inspected.videos.count == (timeline.video == nil ? 0 : 1),
              let measuredDuration = inspected.format.duration.flatMap(Double.init),
              abs(measuredDuration - MediaTimelineReader.seconds(timeline.duration)) <= max(0.1, audio.map { 2048 / Double($0.sampleRate) } ?? 0.001),
              abs(inspected.format.start_time.flatMap(Double.init) ?? 0) <= 0.001 else {
            throw FileformError(.verificationFailed, "Playback proxy streams, duration or normalized clock did not match the recording.")
        }
        try Task.checkCancellation(); try verifyIdentity(timeline)
        transferred = true
        return .init(url: output, directory: directory, identity: timeline.identity, duration: timeline.duration,
            audioStreamIndex: audio?.index, videoStreamIndex: timeline.video?.index,
            warnings: ["Playback preview uses a normalized temporary file. Exports use the original recording."])
    }

    private func reading(_ input: URL) async throws -> MediaTimelineReading {
        try Task.checkCancellation()
        let source = input.standardizedFileURL
        if let cached, cached.timeline.source == source, try FileSafety.identity(source) == cached.timeline.identity { return cached }
        let result = try await MediaTimelineReader(media: MediaBackend(pack: MediaPack(directory: mediaPack))).read(source)
        cached = result; return result
    }

    /// Explicit CLI/export action; the temporary player lease stays separate
    /// from the user's final destination and source aliases remain forbidden.
    public func exportPlaybackPreview(for timeline: MediaTimeline, destination: URL, audioStream: Int? = nil,
                                      muteAudio: Bool = false, maximumDimension: Int = 1280) async throws -> VerifiedResult {
        let transaction = try OutputTransaction(destination: destination, input: timeline.source, collisionPolicy: .fail)
        defer { transaction.cleanup() }
        let preview = try await playbackPreview(for: timeline, audioStream: audioStream, muteAudio: muteAudio, maximumDimension: maximumDimension)
        defer { preview.discard() }
        let format: OutputFormat = timeline.video == nil ? .wav : .mp4
        let candidate = transaction.candidate(0, format: format)
        try FileManager.default.copyItem(at: preview.url, to: candidate)
        try verifyIdentity(timeline); try Task.checkCancellation()
        let bytes = try FileSafety.identity(candidate).bytes
        let output = try transaction.commit(candidate)
        return .init(status: .succeeded, input: timeline.source, output: output, inputBytes: timeline.identity.bytes,
            outputBytes: bytes, format: format, warnings: preview.warnings, attempts: 1)
    }

    public func exportPoster(for timeline: MediaTimeline, destination: URL, at time: MediaTime,
                             maximumDimension: Int = 512) async throws -> VerifiedResult {
        let transaction = try OutputTransaction(destination: destination, input: timeline.source, collisionPolicy: .fail)
        defer { transaction.cleanup() }
        let poster = try await poster(for: timeline, at: time, maximumDimension: maximumDimension)
        let candidate = transaction.candidate(0, format: .png)
        try poster.png.write(to: candidate, options: .withoutOverwriting)
        try verifyIdentity(timeline); try Task.checkCancellation()
        let output = try transaction.commit(candidate)
        return .init(status: .succeeded, input: timeline.source, output: output, inputBytes: timeline.identity.bytes,
            outputBytes: Int64(poster.png.count), format: .png, warnings: ["A measured video frame was rendered as a bounded PNG preview."], attempts: 1)
    }
    private func checked(_ timeline: MediaTimeline) async throws -> MediaTimelineReading {
        let result = try await reading(timeline.source)
        guard result.timeline == timeline else { throw FileformError(.inputChanged, "The media timeline changed. Inspect it again.") }
        return result
    }
    private func verifyIdentity(_ timeline: MediaTimeline) throws {
        guard try FileSafety.identity(timeline.source) == timeline.identity else { throw FileformError(.inputChanged, "The recording changed during preview generation.") }
    }
    private func selectedAudio(_ timeline: MediaTimeline, ordinal: Int?) throws -> MediaAudioTrack {
        guard let ordinal = ordinal ?? (timeline.audioTracks.count == 1 ? 0 : nil),
              let audio = timeline.audioTracks.first(where: { $0.ordinal == ordinal }), audio.timelineCompatible else {
            throw FileformError(.unsupported, "Choose an audio track with a complete, continuous recording clock.")
        }
        return audio
    }
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fileform-media-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func parseWaveform(_ text: String, channels: Int, rate: Int, samples: Int64, maximum: Int) throws -> [MediaWaveformBucket] {
        var buckets: [MediaWaveformBucket] = [], values: [String: String] = [:], expected: Int64 = 0
        func flush() throws {
            guard !values.isEmpty else { return }
            guard let countText = values["Overall.Number_of_samples"], let countDouble = Double(countText), countDouble.isFinite,
                  countDouble > 0, countDouble <= Double(samples), countDouble.rounded() == countDouble else {
                throw FileformError(.verificationFailed, "Waveform sample counts are incomplete.")
            }
            let count = Int64(countDouble)
            var lower: [Float] = [], upper: [Float] = []
            for channel in 1...channels {
                guard let low = values["\(channel).Min_level"].flatMap(Float.init), let high = values["\(channel).Max_level"].flatMap(Float.init),
                      low.isFinite, high.isFinite, low <= high, abs(low) <= 1_000_000, abs(high) <= 1_000_000 else {
                    throw FileformError(.verificationFailed, "Waveform channel measurements are incomplete or invalid.")
                }
                lower.append(low); upper.append(high)
            }
            guard expected + count <= samples, buckets.count < maximum else { throw FileformError(.verificationFailed, "Waveform exceeded its measured bounds.") }
            buckets.append(.init(interval: .init(start: .init(ticks: expected, timescale: Int32(rate)), end: .init(ticks: expected + count, timescale: Int32(rate))), minimum: lower, maximum: upper))
            expected += count; values.removeAll(keepingCapacity: true)
        }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("frame:") { try flush() }
            else if line.hasPrefix("lavfi.astats.") {
                let pair = line.dropFirst("lavfi.astats.".count).split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { throw FileformError(.verificationFailed, "Malformed waveform measurement.") }
                values[String(pair[0])] = String(pair[1])
            }
        }
        try flush()
        guard expected == samples, !buckets.isEmpty else { throw FileformError(.verificationFailed, "Waveform does not cover the complete measured recording.") }
        return buckets
    }
}

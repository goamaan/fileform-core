// SPDX-License-Identifier: Apache-2.0
import Foundation
import FileformDomain

struct MediaTimelineReading: Sendable {
    let timeline: MediaTimeline
    let videoFrameStarts: [MediaTime]
}

struct MediaTimelineReader {
    let media: MediaBackend
    private struct FrameReport: Decodable {
        struct Frame: Decodable { let best_effort_timestamp: Int64?; let duration: Int64? }
        let frames: [Frame]
    }
    func read(_ input: URL) async throws -> MediaTimelineReading {
        let input = input.standardizedFileURL
        let identity = try FileSafety.identity(input)
        let inspection = try await media.inspect(input, identity: identity)
        let probe = try await media.probe(input)
        guard probe.videos.count <= 1, probe.audios.count <= 16 else {
            throw FileformError(.unsupported, "The timeline supports one picture stream and up to sixteen audio tracks.")
        }
        var warnings = inspection.warnings
        var frameStarts: [MediaTime] = []
        let video: MediaVideoTrack?
        if let stream = probe.videos.first {
            guard let index = stream.index, let width = stream.width, let height = stream.height,
                  width > 0, height > 0, width <= 8192, height <= 8192 else { throw invalidClock() }
            let base = try PreviewTimebase(stream.time_base)
            let origin = stream.start_pts ?? 0
            let response = try await ProcessRunner.run(executable: media.pack.ffprobe, arguments: [
                "-v", "error", "-max_alloc", "268435456", "-protocol_whitelist", "file,pipe", "-threads", "2",
                "-select_streams", String(index), "-show_frames", "-show_entries", "frame=best_effort_timestamp,duration",
                "-of", "json=compact=1", input.path
            ], timeout: 120)
            guard response.status == 0, let report = try? JSONDecoder().decode(FrameReport.self, from: response.stdout),
                  !report.frames.isEmpty, report.frames.count <= 100_000 else { throw invalidClock() }
            var previous: Int64?, lastEnd: Int64 = 0, step: Int64?, constant = true
            for frame in report.frames {
                try Task.checkCancellation()
                guard let pts = frame.best_effort_timestamp, let duration = frame.duration,
                      pts >= origin, pts <= Int64.max / 4, origin >= -(Int64.max / 4),
                      duration > 0, duration <= Int64.max / 4, previous.map({ pts > $0 }) ?? true else { throw invalidClock() }
                let relative = pts - origin
                if previous == nil { guard relative == 0 else { throw invalidClock() }; step = duration }
                if duration != step || (previous != nil && relative != lastEnd) { constant = false }
                frameStarts.append(try base.time(relative))
                lastEnd = relative + duration; previous = pts
            }
            let duration = try base.time(lastEnd)
            guard Self.seconds(duration) <= 21_600 else { throw invalidClock() }
            let rotation = stream.side_data_list?.compactMap(\.rotation).first ?? 0
            guard rotation % 90 == 0 else { throw FileformError(.unsupported, "This picture uses an unsupported display rotation.") }
            let sideways = abs(rotation % 180) == 90
            video = .init(index: index, codec: stream.codec_name ?? "unknown", width: width, height: height,
                rotationDegrees: rotation, displayWidth: sideways ? height : width, displayHeight: sideways ? width : height,
                origin: try base.timestamp(origin), duration: duration, frameCount: frameStarts.count,
                frameDuration: constant ? try step.map(base.time) : nil, constantFrameTiming: constant)
            if !constant { warnings.append("This picture has variable frame timing; the current trim route may require timestamp normalization.") }
        } else { video = nil }

        var audio: [MediaAudioTrack] = []
        for (ordinal, stream) in probe.audios.enumerated() {
            try Task.checkCancellation()
            guard let index = stream.index, let rate = stream.sample_rate.flatMap(Int32.init),
                  (8_000...384_000).contains(rate), let channels = stream.channels, (1...8).contains(channels),
                  let ticks = stream.duration_ts, ticks > 0 else { throw invalidClock() }
            let base = try PreviewTimebase(stream.time_base)
            let origin = try base.timestamp(stream.start_pts ?? 0), duration = try base.time(ticks)
            guard Self.seconds(duration) <= 21_600 else { throw invalidClock() }
            var samples: Int64 = 0, limitation: String?
            do { samples = try await MediaTrimBackend(media: media).continuousAudioSamples(input, stream: stream, sampleRate: rate) }
            catch is CancellationError { throw CancellationError() }
            catch { limitation = error.localizedDescription }
            let reference = video?.origin ?? audio.first?.origin ?? origin
            let sameClock = abs(Self.seconds(origin) - Self.seconds(reference)) <= 1 / Double(rate)
            let covered = Double(samples) / Double(rate) + 1 / Double(rate) >= Self.seconds(duration)
            let compatible = limitation == nil && sameClock && covered
            if !sameClock { limitation = "This audio starts on a different clock from the recording." }
            else if limitation == nil && !covered { limitation = "Decoded audio does not cover its declared duration." }
            audio.append(.init(ordinal: ordinal, index: index, codec: stream.codec_name ?? "unknown", sampleRate: Int(rate),
                channels: channels, origin: origin, duration: duration, decodedSamples: samples,
                continuousSampleClock: samples > 0, timelineCompatible: compatible, limitation: limitation))
        }
        guard let duration = video?.duration ?? audio.first?.duration,
              let origin = video?.origin ?? audio.first?.origin else { throw invalidClock() }
        let containerOrigin = probe.format.start_time.flatMap(Double.init) ?? 0
        guard containerOrigin.isFinite, abs(Self.seconds(origin) - containerOrigin) <= 0.001 else { throw invalidClock() }
        try FileSafety.verifyUnchanged(inspection)
        // A proxy is the conservative default; no codec name alone proves that
        // AVPlayer has loaded a file with the same stream selection and clock.
        return .init(timeline: .init(source: input, identity: identity, container: probe.format.format_name ?? "media",
            duration: duration, origin: origin, audioTracks: audio, video: video,
            originalPlaybackReliable: false, warnings: warnings), videoFrameStarts: frameStarts)
    }
    static func seconds(_ time: MediaTime) -> Double { Double(time.ticks) / Double(time.timescale) }
    static func seconds(_ time: MediaTimestamp) -> Double { Double(time.ticks) / Double(time.timescale) }
    private func invalidClock() -> FileformError { .init(.unsupported, "A complete, bounded recording timeline could not be measured.") }
}

struct PreviewTimebase {
    let numerator: Int64
    let denominator: Int32
    init(_ text: String?) throws {
        let parts = text?.split(separator: "/") ?? []
        guard parts.count == 2, let n = Int64(parts[0]), let d = Int32(parts[1]), n > 0, d > 0 else {
            throw FileformError(.unsupported, "The stream has no supported rational clock.")
        }
        numerator = n; denominator = d
    }
    func timestamp(_ ticks: Int64) throws -> MediaTimestamp {
        let value = ticks.multipliedReportingOverflow(by: numerator)
        guard !value.overflow else { throw FileformError(.resourceLimit, "Media clock overflow.") }
        return .init(ticks: value.partialValue, timescale: denominator)
    }
    func time(_ ticks: Int64) throws -> MediaTime {
        let value = try timestamp(ticks)
        let result = MediaTime(ticks: value.ticks, timescale: value.timescale)
        try result.validate(); return result
    }
}

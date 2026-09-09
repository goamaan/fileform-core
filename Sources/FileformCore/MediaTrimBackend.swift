// SPDX-License-Identifier: Apache-2.0
import Foundation
import FileformDomain

/// Bounded local trimming with explicit source-clock measurements. Native media
/// timing is inspected again at execution; a serialized plan cannot choose flags.
struct MediaTrimBackend {
    let media: MediaBackend
    private static let maximumPackets = 100_000

    private struct Packet: Decodable {
        let pts: Int64?
        let dts: Int64?
        let duration: Int64?
        let flags: String?
        let data_hash: String?
    }
    private struct PacketReport: Decodable { let packets: [Packet] }
    private struct AudioFrameReport: Decodable {
        struct Frame: Decodable {
            let pts: Int64?
            let nb_samples: Int?
        }
        let frames: [Frame]
    }
    private struct Timebase {
        let numerator: Int64
        let denominator: Int32
        init(_ text: String?) throws {
            let parts = text?.split(separator: "/") ?? []
            guard parts.count == 2, let n = Int64(parts[0]), let d = Int32(parts[1]), n > 0, d > 0 else {
                throw FileformError(.unsupported, "The selected stream has no supported rational time base.")
            }
            numerator = n; denominator = d
        }
        func time(_ ticks: Int64) throws -> MediaTime {
            let value = ticks.multipliedReportingOverflow(by: numerator)
            guard ticks >= 0, !value.overflow else { throw FileformError(.unsupported, "Stream timestamps exceed the supported range.") }
            return .init(ticks: value.partialValue, timescale: denominator)
        }
        func seconds(_ ticks: Int64) -> Double { Double(ticks) * Double(numerator) / Double(denominator) }
    }
    private struct Resolved {
        let request: TransformationRequest
        let inspection: Inspection
        let video: MediaBackend.Probe.Stream?
        let audio: MediaBackend.Probe.Stream?
        let details: MediaTrimDetails
        let warnings: [String]
        let videoStartFrame: Int?
        let videoEndFrame: Int?
        let sampleStart: Int64?
        let sampleEnd: Int64?
    }

    func plan(_ request: TransformationRequest, inspection: Inspection) async throws -> TransformationPlan {
        let resolved = try await resolve(request, inspection: inspection)
        return .init(request: request, inputs: [.init(id: request.assets[0].id, inspection: inspection)],
                     warnings: resolved.warnings, mediaTrim: resolved.details)
    }

    func execute(_ plan: TransformationPlan, progress: @Sendable (ProgressEvent) -> Void) async throws -> TransformationResult {
        try Task.checkCancellation()
        try plan.request.validate()
        guard plan.schemaVersion == 1, plan.inputs.count == 1, plan.request.assets.count == 1,
              plan.inputs[0].id == plan.request.assets[0].id,
              plan.inputs[0].inspection.input == plan.request.assets[0].url.standardizedFileURL,
              let approved = plan.mediaTrim else {
            throw FileformError(.invalidRequest, "The trim plan is missing its measured source binding.")
        }
        let recorded = plan.inputs[0].inspection
        try FileSafety.verifyUnchanged(recorded)
        let current = try await media.inspect(recorded.input, identity: FileSafety.identity(recorded.input))
        let resolved = try await resolve(plan.request, inspection: current)
        guard current.identity == recorded.identity, resolved.details == approved else {
            throw FileformError(.inputChanged, "The measured trim interval changed. Inspect and approve a new plan.")
        }
        progress(.init(.preparing))
        let transaction = try OutputTransaction(destination: plan.request.output.destination, input: current.input,
                                                collisionPolicy: plan.request.collisionPolicy)
        defer { transaction.cleanup() }
        let candidate = transaction.candidate(0, format: plan.request.output.format)
        progress(.init(.encoding))
        try await encode(resolved, destination: candidate)
        try Task.checkCancellation()
        progress(.init(.verifying))
        let outputDuration = try await verify(candidate, resolved: resolved)
        let bytes = try FileSafety.identity(candidate).bytes
        try FileSafety.verifyUnchanged(current)
        try Task.checkCancellation()
        progress(.init(.saving))
        let output = try transaction.commit(candidate)
        let details = resolved.details
        return .init(operationID: .mediaTrim, status: .succeeded,
                     artifacts: [.init(url: output, format: plan.request.output.format, bytes: bytes,
                                       sourceIDs: [plan.request.assets[0].id])],
                     warnings: resolved.warnings, attempts: 1,
                     mediaTrim: .init(requested: details.requested, realized: details.realized, mode: details.mode,
                                      videoStreamIndex: details.videoStreamIndex, audioStreamIndex: details.audioStreamIndex,
                                      copiedStreams: details.copiedStreams, durationTolerance: details.durationTolerance,
                                      outputDuration: outputDuration))
    }

    private func resolve(_ request: TransformationRequest, inspection: Inspection) async throws -> Resolved {
        try Task.checkCancellation()
        try request.validate()
        guard case .mediaTrim(let requested, let mode, let audioOrdinal, let muteAudio) = request.operation,
              inspection.family == .media, request.assets.count == 1,
              inspection.input == request.assets[0].url.standardizedFileURL else {
            throw FileformError(.invalidRequest, "Trimming requires one inspected recording.")
        }
        guard request.fidelity == .allowDeclaredLosses else {
            throw FileformError(.unsupported, "Trim removes document-level metadata and does not promise complete lossless preservation.")
        }
        let format = request.output.format
        guard MediaBackend.formats.contains(format) else { throw FileformError(.unsupported, "This trim output is not installed. MP3 requires a separate encoder pack.") }
        try FileSafety.verifyUnchanged(inspection)
        try FileSafety.rejectSourceAliases(destination: request.output.destination, inputs: [inspection])
        let source = try await media.probe(inspection.input)
        let videoOutput = [.mp4, .mov].contains(format)
        let video: MediaBackend.Probe.Stream?
        if videoOutput {
            guard source.videos.count == 1 else { throw FileformError(.unsupported, "Video trimming requires exactly one picture stream.") }
            guard !source.streams.contains(where: { ["subtitle", "data", "attachment"].contains($0.codec_type ?? "") }) else {
                throw FileformError(.unsupported, "This video has subtitle, data or attachment streams requiring an explicit preservation workflow.")
            }
            video = source.videos[0]
            try validateVideo(source.videos[0], mode: mode)
        } else { video = nil }
        let audio: MediaBackend.Probe.Stream?
        if muteAudio { audio = nil }
        else if let ordinal = audioOrdinal {
            guard source.audios.indices.contains(ordinal) else { throw FileformError(.invalidRequest, "The selected audio-stream ordinal does not exist.") }
            audio = source.audios[ordinal]
        } else {
            guard source.audios.count <= 1 else { throw FileformError(.invalidRequest, "Choose an audio stream explicitly when a recording contains several tracks.") }
            audio = source.audios.first
        }
        guard video != nil || audio != nil else { throw FileformError(.unsupported, "The input has no stream for this output.") }
        if !videoOutput && audio == nil { throw FileformError(.invalidRequest, "An audio-only trim needs an audio stream.") }
        if let audio { try validateAudio(audio, format: format, mode: mode) }
        if mode == .copy {
            guard source.format.format_name?.split(separator: ",").contains("mov") == true,
                  [.mp4, .mov, .m4a].contains(format), video?.codec_name == nil || video?.codec_name == "h264",
                  audio?.codec_name == nil || audio?.codec_name == "aac" else {
                throw FileformError(.unsupported, "Fast trim currently copies H.264/AAC from MP4/MOV-family inputs into MP4, MOV or M4A. Use exact mode for other codecs.")
            }
        }
        let primary = video ?? audio!
        let primaryBase = try Timebase(primary.time_base)
        let primaryOrigin = primary.start_pts ?? 0
        let originSeconds = primaryBase.seconds(primaryOrigin)
        let containerOrigin = source.format.start_time.flatMap(Double.init) ?? 0
        guard primaryOrigin >= 0, primaryOrigin <= Int64.max / 4, originSeconds.isFinite, (0...21600).contains(originSeconds),
              containerOrigin.isFinite, abs(originSeconds - containerOrigin) <= 0.001 else {
            throw FileformError(.unsupported, "The selected stream starts on a different clock from its container. Normalize timestamps before trimming.")
        }
        let sampleRate = try audio.map { audio -> Int32 in
            guard let rate = audio.sample_rate.flatMap(Int32.init), (8_000...384_000).contains(rate) else {
                throw FileformError(.unsupported, "This audio sample rate is not supported for trimming.")
            }
            let base = try Timebase(audio.time_base)
            guard (0...(Int64.max / 4)).contains(audio.start_pts ?? 0),
                  abs(base.seconds(audio.start_pts ?? 0) - originSeconds) <= 1 / Double(rate) else {
                throw FileformError(.unsupported, "Picture and selected audio have different start offsets. An explicit synchronization workflow is required.")
            }
            return rate
        }
        // atrim's sample-index mode counts decoded samples, not elapsed source
        // time. Prove that the selected decoded stream has a continuous clock
        // before using this mapping; packet durations can conceal clock gaps.
        let decodedAudioSamples: Int64?
        if mode == .exact, let audio, let sampleRate {
            decodedAudioSamples = try await continuousAudioSamples(inspection.input, stream: audio, sampleRate: sampleRate)
        } else { decodedAudioSamples = nil }
        var videoStartFrame: Int?, videoEndFrame: Int?
        let realized: MediaInterval
        var maximumPacketSeconds = audio == nil ? 0 : 1024 / Double(sampleRate!)
        if let video {
            guard let streamIndex = video.index else { throw FileformError(.unsupported, "The picture stream has no stable index.") }
            let packets = try await packets(inspection.input, stream: streamIndex)
            let ordered = packets.sorted { ($0.pts ?? Int64.min) < ($1.pts ?? Int64.min) }
            guard let first = ordered.first, first.pts == primaryOrigin, let frameTicks = first.duration, frameTicks > 0 else {
                throw FileformError(.unsupported, "The video has no complete measurable frame timeline.")
            }
            for (index, packet) in ordered.enumerated() {
                let delta = Int64(index).multipliedReportingOverflow(by: frameTicks)
                let expected = primaryOrigin.addingReportingOverflow(delta.partialValue)
                guard !delta.overflow, !expected.overflow, packet.pts == expected.partialValue,
                      packet.duration == frameTicks, mode != .copy || packet.dts == packet.pts else {
                    throw FileformError(.unsupported, "This trim route requires constant-rate video with complete timestamps; fast mode additionally requires no reordered frames.")
                }
            }
            let totalTicks = frameTicks.multipliedReportingOverflow(by: Int64(ordered.count))
            guard !totalTicks.overflow else { throw FileformError(.resourceLimit, "Video timeline overflow.") }
            let duration = try primaryBase.time(totalTicks.partialValue)
            guard Self.seconds(duration) <= 21600 else { throw FileformError(.resourceLimit, "Video timeline exceeds six hours.") }
            try requested.validate(duration: duration)
            let starts = try ordered.map { try primaryBase.time($0.pts! - primaryOrigin) }
            let startIndex: Int
            let endIndex: Int
            if mode == .exact {
                startIndex = try starts.firstIndex(where: { try !$0.isBefore(requested.start) }) ?? starts.count
                endIndex = try starts.firstIndex(where: { try !$0.isBefore(requested.end) }) ?? starts.count
            } else {
                let keys = ordered.indices.filter { ordered[$0].flags?.contains("K") == true }
                guard let beginning = try keys.last(where: { try !requested.start.isBefore(starts[$0]) }) else {
                    throw FileformError(.unsupported, "No preceding independently decodable keyframe was found.")
                }
                startIndex = beginning
                endIndex = try keys.first(where: { try !starts[$0].isBefore(requested.end) }) ?? starts.count
            }
            guard startIndex < endIndex else { throw FileformError(.invalidRequest, "The selected interval contains no complete video-frame onset.") }
            realized = .init(start: starts[startIndex], end: endIndex == starts.count ? duration : starts[endIndex])
            videoStartFrame = startIndex; videoEndFrame = endIndex
            maximumPacketSeconds = max(maximumPacketSeconds, 0.001)
        } else {
            guard let audio, let sampleRate, let durationTicks = audio.duration_ts, durationTicks > 0 else {
                throw FileformError(.unsupported, "The audio has no measurable complete duration.")
            }
            let duration = try primaryBase.time(durationTicks)
            guard Self.seconds(duration) <= 21600 else { throw FileformError(.resourceLimit, "Audio timeline exceeds six hours.") }
            try requested.validate(duration: duration)
            if mode == .exact {
                realized = .init(start: .init(ticks: try Self.ceilTicks(requested.start, at: sampleRate), timescale: sampleRate),
                                 end: .init(ticks: try Self.ceilTicks(requested.end, at: sampleRate), timescale: sampleRate))
                maximumPacketSeconds = format == .m4a ? 1024 / Double(sampleRate) : 1 / Double(sampleRate)
            } else {
                guard let index = audio.index else { throw FileformError(.unsupported, "The audio stream has no stable index.") }
                let all = try await packets(inspection.input, stream: index)
                let usable = all.filter { ($0.pts ?? Int64.min) >= primaryOrigin }
                guard !usable.isEmpty, usable.allSatisfy({ $0.pts != nil && ($0.duration ?? 0) > 0 && $0.pts == $0.dts }) else {
                    throw FileformError(.unsupported, "Fast audio trimming needs complete ordered packet timestamps.")
                }
                let starts = try usable.map { try primaryBase.time($0.pts! - primaryOrigin) }
                guard let start = try starts.last(where: { try !requested.start.isBefore($0) }) else {
                    throw FileformError(.unsupported, "No eligible audio packet boundary was found.")
                }
                let end = try starts.first(where: { try !$0.isBefore(requested.end) }) ?? duration
                realized = .init(start: start, end: end)
                maximumPacketSeconds = max(maximumPacketSeconds, usable.map { primaryBase.seconds($0.duration!) }.max() ?? 0)
            }
        }
        try realized.validate()
        guard Self.seconds(realized.end) <= 6 * 3600 else { throw FileformError(.resourceLimit, "Trim supports source intervals within six hours.") }
        let sampleStart = try sampleRate.map { try Self.ceilTicks(realized.start, at: $0) }
        let sampleEnd = try sampleRate.map { try Self.ceilTicks(realized.end, at: $0) }
        if let sampleEnd, let decodedAudioSamples, sampleEnd > decodedAudioSamples {
            throw FileformError(.invalidRequest, "The selected interval exceeds the complete decoded audio content.")
        }
        if let audio, let ticks = audio.duration_ts {
            let duration = try Timebase(audio.time_base).time(ticks)
            guard Self.seconds(realized.end) <= Self.seconds(duration) + 1 / Double(sampleRate!) else {
                throw FileformError(.invalidRequest, "The selected audio does not cover the complete requested picture interval.")
            }
        }
        guard maximumPacketSeconds.isFinite, (0...60).contains(maximumPacketSeconds) else {
            throw FileformError(.unsupported, "The selected stream has an unsupported packet duration.")
        }
        let tolerance = MediaTime(ticks: max(1, Int64(ceil(maximumPacketSeconds * 1_000_000))), timescale: 1_000_000)
        let details = MediaTrimDetails(requested: requested, realized: realized, mode: mode,
                                       videoStreamIndex: video?.index, audioStreamIndex: audio?.index,
                                       copiedStreams: mode == .copy, durationTolerance: tolerance)
        var warnings = ["Descriptive metadata, chapters, cover artwork and unselected audio tracks are removed."]
        if muteAudio { warnings.append("Audio is explicitly muted. All source audio tracks are omitted from this video output.") }
        if mode == .copy {
            warnings.append("Fast trim copies encoded packets. The measured range snaps outward to eligible keyframe or audio-packet boundaries.")
            if audio != nil { warnings.append("Compressed audio may overlap the selected edges by one packet; measured output duration and tolerance are reported.") }
        } else {
            warnings.append("Exact trim selects source frame/sample onsets in the requested half-open range; the reported range is quantized to those boundaries.")
            if video != nil || format == .m4a { warnings.append("H.264/AAC output is re-encoded and may lose detail.") }
            if format == .wav { warnings.append("WAV output uses 16-bit PCM. Higher precision or floating-point source audio is reduced explicitly.") }
        }
        if !videoOutput && !source.videos.isEmpty { warnings.append("This produces only the selected audio; the original picture remains in your source.") }
        if let audioOrdinal { warnings.append("Selected audio ordinal \(audioOrdinal) resolves to source stream \(audio!.index ?? -1).") }
        try FileSafety.verifyUnchanged(inspection)
        return .init(request: request, inspection: inspection, video: video, audio: audio, details: details, warnings: warnings,
                     videoStartFrame: videoStartFrame, videoEndFrame: videoEndFrame, sampleStart: sampleStart, sampleEnd: sampleEnd)
    }

    private func validateVideo(_ video: MediaBackend.Probe.Stream, mode: TrimMode) throws {
        let pixel = video.pix_fmt ?? ""
        let rotation = video.side_data_list?.compactMap(\.rotation).first ?? 0
        guard let width = video.width, let height = video.height, (2...8192).contains(width), (2...8192).contains(height),
              width % 2 == 0, height % 2 == 0, [nil, "1:1", "0:1", "N/A"].contains(video.sample_aspect_ratio),
              !["smpte2084", "arib-std-b67"].contains(video.color_transfer ?? ""),
              !pixel.contains("10"), !pixel.contains("12"), !pixel.contains("16"),
              !["yuva", "rgba", "argb", "bgra", "abgr", "gbrap"].contains(where: pixel.hasPrefix),
              rotation % 90 == 0, mode != .copy || video.has_b_frames == 0 else {
            throw FileformError(.unsupported, "Trim requires even-sized, square-pixel SDR video without alpha; fast mode requires no reordered frames.")
        }
    }

    private func validateAudio(_ audio: MediaBackend.Probe.Stream, format: OutputFormat, mode: TrimMode) throws {
        guard audio.index != nil, let channels = audio.channels, (1...8).contains(channels) else {
            throw FileformError(.unsupported, "The selected audio channel layout is unsupported.")
        }
        let bits = max(audio.bits_per_sample ?? 0, audio.bits_per_raw_sample.flatMap(Int.init) ?? 0)
        if format == .flac, (audio.sample_fmt?.hasPrefix("flt") == true || audio.sample_fmt?.hasPrefix("dbl") == true || bits > 24) {
            // Lossy AAC decodes to float; conversion into integer FLAC is permitted
            // only through the existing explicit conversion route, not this trim.
            throw FileformError(.unsupported, "FLAC trimming currently accepts integer PCM/FLAC audio up to 24 bits. Use WAV or M4A for floating-point decoded sources.")
        }
        if mode == .copy && audio.codec_name != "aac" { throw FileformError(.unsupported, "Fast audio trimming currently copies AAC packets. Use exact mode for PCM or FLAC.") }
    }

    private func packets(_ input: URL, stream: Int, hashes: Bool = false) async throws -> [Packet] {
        var arguments = ["-v", "error", "-max_alloc", "268435456", "-protocol_whitelist", "file,pipe",
                         "-select_streams", String(stream), "-show_packets", "-show_entries", "packet=pts,dts,duration,flags,data_hash", "-of", "json=compact=1"]
        if hashes { arguments += ["-show_data_hash", "sha256"] }
        arguments.append(input.path)
        let result = try await ProcessRunner.run(executable: media.pack.ffprobe, arguments: arguments, timeout: 60)
        guard result.status == 0, let report = try? JSONDecoder().decode(PacketReport.self, from: result.stdout), !report.packets.isEmpty else {
            throw FileformError(.unsupported, "The selected stream's packet timeline could not be read completely.")
        }
        guard report.packets.count <= Self.maximumPackets else { throw FileformError(.resourceLimit, "Trim inspection exceeds the current 100000-packet bound.") }
        guard report.packets.allSatisfy({ packet in
            guard let pts = packet.pts, let duration = packet.duration else { return false }
            return (-(Int64.max / 4)...(Int64.max / 4)).contains(pts) && (1...(Int64.max / 4)).contains(duration)
        }) else { throw FileformError(.unsupported, "The selected stream has incomplete or out-of-range packet timestamps.") }
        return report.packets
    }

    private func continuousAudioSamples(_ input: URL, stream: MediaBackend.Probe.Stream, sampleRate: Int32) async throws -> Int64 {
        guard let index = stream.index else { throw FileformError(.unsupported, "The audio stream has no stable index.") }
        let result = try await ProcessRunner.run(executable: media.pack.ffprobe, arguments: [
            "-v", "error", "-max_alloc", "268435456", "-protocol_whitelist", "file,pipe", "-threads", "2",
            "-select_streams", String(index), "-show_frames", "-show_entries", "frame=pts,nb_samples",
            "-of", "json=compact=1", input.path
        ], timeout: 120)
        guard result.status == 0, let report = try? JSONDecoder().decode(AudioFrameReport.self, from: result.stdout),
              !report.frames.isEmpty else {
            throw FileformError(.unsupported, "The selected audio's decoded timeline could not be established.")
        }
        guard report.frames.count <= Self.maximumPackets else {
            throw FileformError(.resourceLimit, "Exact trim inspection exceeds the current 100000 decoded-audio-frame bound.")
        }
        let base = try Timebase(stream.time_base)
        let origin = stream.start_pts ?? 0
        var samples: Int64 = 0
        let maximumSamples = (6 * 3600 + 1) * Int64(sampleRate)
        for frame in report.frames {
            try Task.checkCancellation()
            guard let pts = frame.pts, pts >= origin, pts <= Int64.max / 4,
                  let count = frame.nb_samples, count > 0, count <= Int(sampleRate) * 60 else {
                throw FileformError(.unsupported, "Exact trim requires complete, bounded decoded-audio timestamps and sample counts.")
            }
            let timestamp = try base.time(pts - origin)
            let expected = MediaTime(ticks: samples, timescale: sampleRate)
            guard try !timestamp.isBefore(expected), try !expected.isBefore(timestamp) else {
                throw FileformError(.unsupported, "Exact trim requires a continuous, sample-resolved audio clock. This stream has gaps, overlaps or imprecise timestamps.")
            }
            let next = samples.addingReportingOverflow(Int64(count))
            guard !next.overflow, next.partialValue <= maximumSamples else {
                throw FileformError(.resourceLimit, "Decoded audio exceeds the supported trim duration.")
            }
            samples = next.partialValue
        }
        return samples
    }

    private func encode(_ resolved: Resolved, destination: URL) async throws {
        let details = resolved.details
        let duration = Self.seconds(details.realized.end) - Self.seconds(details.realized.start)
        var args = ["-hide_banner", "-nostdin", "-v", "error", "-nostats", "-xerror", "-max_alloc", "268435456",
                    "-protocol_whitelist", "file,pipe", "-threads", "2"]
        if details.mode == .copy && resolved.video != nil { args += ["-ss", Self.decimal(Self.seconds(details.realized.start))] }
        args += ["-i", resolved.inspection.input.path, "-map_metadata", "-1", "-map_chapters", "-1"]
        // An input seek may follow an unselected picture stream's earlier GOP.
        // Audio-only copy instead discards packets up to its measured boundary.
        if details.mode == .copy && resolved.video == nil {
            args += ["-ss", Self.decimal(floor(Self.seconds(details.realized.start) * 1_000_000) / 1_000_000)]
        }
        if let video = details.videoStreamIndex { args += ["-map", "0:\(video)"] }
        if let audio = details.audioStreamIndex { args += ["-map", "0:\(audio)"] }
        else { args += ["-an"] }
        if details.mode == .copy {
            args += ["-t", Self.decimal(duration), "-c", "copy", "-copytb", "1", "-avoid_negative_ts", "disabled"]
        } else {
            if let start = resolved.videoStartFrame, let end = resolved.videoEndFrame {
                args += ["-vf", "trim=start_frame=\(start):end_frame=\(end),setpts=PTS-STARTPTS",
                         "-fps_mode", "passthrough", "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "2000000",
                         "-bf", "0", "-pix_fmt", "yuv420p", "-filter_threads", "2"]
            }
            if let start = resolved.sampleStart, let end = resolved.sampleEnd {
                args += ["-af", "atrim=start_sample=\(start):end_sample=\(end),asetpts=PTS-STARTPTS"]
                switch resolved.request.output.format {
                case .wav: args += ["-c:a", "pcm_s16le"]
                case .flac: args += ["-c:a", "flac", "-compression_level", "8"]
                default: args += ["-c:a", "aac", "-b:a", "128000"]
                }
            }
        }
        if [.mp4, .mov, .m4a].contains(resolved.request.output.format) { args += ["-movflags", "+faststart"] }
        args += ["-n", destination.path]
        let result = try await ProcessRunner.run(executable: media.pack.ffmpeg, arguments: args,
                                                timeout: min(12 * 3600, max(120, (resolved.inspection.duration ?? duration) * 4 + 60)))
        guard result.status == 0 else { throw FileformError(.engineFailed, "The selected media interval could not be encoded. The original is unchanged.") }
    }

    private func verify(_ output: URL, resolved: Resolved) async throws -> MediaTime {
        let check = try await media.probe(output)
        let details = resolved.details
        let expected = Self.seconds(details.realized.end) - Self.seconds(details.realized.start)
        let tolerance = Self.seconds(details.durationTolerance) + 0.001
        guard let duration = check.format.duration.flatMap(Double.init), duration.isFinite, duration > 0,
              abs(duration - expected) <= tolerance,
              abs(check.format.start_time.flatMap(Double.init) ?? 0) <= 0.001,
              check.videos.count == (resolved.video == nil ? 0 : 1), check.audios.count == (resolved.audio == nil ? 0 : 1) else {
            throw FileformError(.verificationFailed, "Trim output failed measured duration, origin or stream-count verification.")
        }
        let containers = check.format.format_name?.split(separator: ",") ?? []
        let expectedContainer = switch resolved.request.output.format { case .wav: "wav"; case .flac: "flac"; default: "mov" }
        guard containers.contains(Substring(expectedContainer)) else { throw FileformError(.verificationFailed, "Trim output container does not match the plan.") }
        if let video = resolved.video, let outputVideo = check.videos.first {
            var width = video.width, height = video.height
            let rotation = video.side_data_list?.compactMap(\.rotation).first ?? 0
            if details.mode == .exact && abs(rotation) % 180 == 90 { swap(&width, &height) }
            guard outputVideo.codec_name == "h264", outputVideo.width == width, outputVideo.height == height,
                  let index = outputVideo.index else { throw FileformError(.verificationFailed, "Trim output picture properties changed unexpectedly.") }
            let timeline = try await packets(output, stream: index)
            guard timeline.count == resolved.videoEndFrame! - resolved.videoStartFrame!,
                  let first = timeline.first, first.flags?.contains("K") == true else {
                throw FileformError(.verificationFailed, "Trim output did not retain every selected video frame or an independently decodable start.")
            }
        }
        if let audio = resolved.audio, let outputAudio = check.audios.first {
            let expectedCodec = switch resolved.request.output.format { case .wav: "pcm_s16le"; case .flac: "flac"; default: "aac" }
            guard outputAudio.codec_name == expectedCodec, outputAudio.sample_rate == audio.sample_rate,
                  outputAudio.channels == audio.channels else {
                throw FileformError(.verificationFailed, "Trim output audio codec, channel count or sample rate changed unexpectedly.")
            }
        }
        if details.copiedStreams {
            if let source = resolved.video, let destination = check.videos.first {
                try await verifyCopiedPackets(source: source, destination: destination, input: resolved.inspection.input,
                                              output: output, details: details, video: true)
            }
            if let source = resolved.audio, let destination = check.audios.first {
                try await verifyCopiedPackets(source: source, destination: destination, input: resolved.inspection.input,
                                              output: output, details: details, video: false)
            }
        } else if let audio = resolved.audio, [.wav, .flac].contains(resolved.request.output.format) {
            // Independent decoded PCM hashes verify sample content for integer
            // lossless routes, including the exact first/last sample boundaries.
            let bits = max(audio.bits_per_sample ?? 0, audio.bits_per_raw_sample.flatMap(Int.init) ?? 0)
            let integerSource = !(audio.sample_fmt?.hasPrefix("flt") ?? false) && !(audio.sample_fmt?.hasPrefix("dbl") ?? false)
            if integerSource && (resolved.request.output.format == .flac || bits <= 16) {
                let expectedHash = try await pcmHash(resolved.inspection.input, stream: audio.index!,
                                                    start: resolved.sampleStart, end: resolved.sampleEnd)
                let actualHash = try await pcmHash(output, stream: check.audios[0].index!, start: nil, end: nil)
                guard expectedHash == actualHash else { throw FileformError(.verificationFailed, "Trimmed PCM samples did not match the selected source interval.") }
            }
        }
        let decoded = try await ProcessRunner.run(executable: media.pack.ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-xerror", "-err_detect", "explode", "-max_alloc", "268435456",
            "-protocol_whitelist", "file,pipe", "-threads", "2", "-i", output.path,
            "-map", "0:v?", "-map", "0:a?", "-f", "null", "-"
        ], timeout: min(12 * 3600, max(120, duration * 4 + 60)))
        guard decoded.status == 0 else { throw FileformError(.verificationFailed, "The complete trimmed output did not decode successfully.") }
        return .init(ticks: Int64((duration * 1_000_000).rounded()), timescale: 1_000_000)
    }

    private func verifyCopiedPackets(source: MediaBackend.Probe.Stream, destination: MediaBackend.Probe.Stream,
                                     input: URL, output: URL, details: MediaTrimDetails, video: Bool) async throws {
        guard let sourceIndex = source.index, let destinationIndex = destination.index else {
            throw FileformError(.verificationFailed, "Copied streams lost their indices.")
        }
        let original = try await packets(input, stream: sourceIndex, hashes: true)
        let copied = try await packets(output, stream: destinationIndex, hashes: true)
        let sourceBase = try Timebase(source.time_base), destinationBase = try Timebase(destination.time_base)
        guard let first = copied.first, let firstHash = first.data_hash, let firstPTS = first.pts,
              let match = original.firstIndex(where: { packet in
                  guard packet.data_hash == firstHash, let pts = packet.pts else { return false }
                  return abs(sourceBase.seconds(pts - (source.start_pts ?? 0)) - Self.seconds(details.realized.start) - destinationBase.seconds(firstPTS)) <= 0.001
              }), match + copied.count <= original.count else {
            throw FileformError(.verificationFailed, "The copied packets did not originate at the approved source boundary.")
        }
        for (offset, packet) in copied.enumerated() {
            let sourcePacket = original[match + offset]
            guard let hash = packet.data_hash, hash == sourcePacket.data_hash,
                  let sourcePTS = sourcePacket.pts, let outputPTS = packet.pts,
                  abs(sourceBase.seconds(sourcePTS - (source.start_pts ?? 0)) - Self.seconds(details.realized.start)
                      - destinationBase.seconds(outputPTS)) <= 0.001 else {
                throw FileformError(.verificationFailed, "Fast trim changed encoded packet content or timing.")
            }
        }
        guard let last = original[safe: match + copied.count - 1], let lastPTS = last.pts, let lastDuration = last.duration,
              let originalFirst = original[match].pts else { throw FileformError(.verificationFailed, "Copied packet bounds are incomplete.") }
        let start = sourceBase.seconds(originalFirst - (source.start_pts ?? 0))
        let end = sourceBase.seconds(lastPTS + lastDuration - (source.start_pts ?? 0))
        let tolerance = video ? 0.001 : Self.seconds(details.durationTolerance) + 0.001
        guard abs(start - Self.seconds(details.realized.start)) <= tolerance,
              abs(end - Self.seconds(details.realized.end)) <= tolerance,
              start <= Self.seconds(details.realized.start) + 0.001,
              end >= Self.seconds(details.realized.end) - 0.001 else {
            throw FileformError(.verificationFailed, "Fast trim's measured packet range differs from the approved interval.")
        }
    }

    private func pcmHash(_ input: URL, stream: Int, start: Int64?, end: Int64?) async throws -> Data {
        var args = ["-v", "error", "-nostdin", "-xerror", "-max_alloc", "268435456", "-protocol_whitelist", "file,pipe",
                    "-i", input.path, "-map", "0:\(stream)"]
        if let start, let end { args += ["-af", "atrim=start_sample=\(start):end_sample=\(end),asetpts=PTS-STARTPTS"] }
        args += ["-c:a", "pcm_s32le", "-f", "hash", "-hash", "sha256", "-"]
        let result = try await ProcessRunner.run(executable: media.pack.ffmpeg, arguments: args, timeout: 120)
        guard result.status == 0, String(decoding: result.stdout, as: UTF8.self).hasPrefix("SHA256=") else {
            throw FileformError(.verificationFailed, "Selected PCM sample content could not be verified.")
        }
        return result.stdout
    }

    private static func seconds(_ time: MediaTime) -> Double { Double(time.ticks) / Double(time.timescale) }
    private static func decimal(_ seconds: Double) -> String { String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), seconds) }
    private static func ceilTicks(_ time: MediaTime, at timescale: Int32) throws -> Int64 {
        try time.validate()
        guard time.ticks <= Int64(time.timescale) * 6 * 3600, timescale > 0 else { throw FileformError(.resourceLimit, "The trim time exceeds six hours.") }
        let product = time.ticks.multipliedFullWidth(by: Int64(timescale))
        let result = Int64(time.timescale).dividingFullWidth(product)
        return result.quotient + (result.remainder == 0 ? 0 : 1)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

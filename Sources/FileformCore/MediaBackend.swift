// SPDX-License-Identifier: Apache-2.0
import Foundation
import FileformDomain

struct MediaBackend: Sendable {
    let pack: MediaPack
    static let formats: [OutputFormat] = [.mp4, .mov, .m4a, .wav, .flac]

    struct Probe: Decodable {
        struct Stream: Decodable {
            let codec_type: String?
            let codec_name: String?
            let width: Int?
            let height: Int?
            let pix_fmt: String?
            let color_transfer: String?
            let duration: String?
            let channels: Int?
            let sample_rate: String?
            let sample_fmt: String?
            let bits_per_sample: Int?
            let bits_per_raw_sample: String?
            let sample_aspect_ratio: String?
            let disposition: [String: Int]?
            let side_data_list: [SideData]?
            struct SideData: Decodable { let rotation: Int? }
        }
        struct Format: Decodable { let format_name: String?; let duration: String?; let bit_rate: String? }
        let streams: [Stream]
        let format: Format
        var videos: [Stream] { streams.filter { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 } }
        var audios: [Stream] { streams.filter { $0.codec_type == "audio" } }
    }

    func probe(_ input: URL) async throws -> Probe {
        let response = try await ProcessRunner.run(executable: pack.ffprobe, arguments: [
            "-v", "error", "-max_alloc", "268435456", "-protocol_whitelist", "file,pipe",
            "-show_format", "-show_streams", "-of", "json", input.path
        ], timeout: 30)
        guard response.status == 0, let probe = try? JSONDecoder().decode(Probe.self, from: response.stdout) else {
            throw FileformError(.unsupported, "The media could not be inspected. It may be damaged or use an unsupported format.")
        }
        return probe
    }

    func inspect(_ input: URL, identity: FileIdentity) async throws -> Inspection {
        let info = try await probe(input)
        guard !info.videos.isEmpty || !info.audios.isEmpty,
              let duration = info.format.duration.flatMap(Double.init), duration.isFinite, duration > 0 else {
            throw FileformError(.unsupported, "No finite audio or video duration could be established.")
        }
        guard duration <= 6 * 60 * 60 else { throw FileformError(.resourceLimit, "The current media workflow accepts recordings up to six hours.") }
        var warnings = [String]()
        if info.videos.count > 1 || info.audios.count > 1 { warnings.append("Multiple video or audio tracks need an explicit selection workflow that is not available yet.") }
        if info.streams.contains(where: { $0.codec_type == "subtitle" }) { warnings.append("Embedded subtitle preservation is not available for this route yet.") }
        if let video = info.videos.first {
            if let aspect = video.sample_aspect_ratio, !["1:1", "0:1", "N/A"].contains(aspect) {
                warnings.append("Non-square video pixels need an explicit aspect-ratio workflow that is not available yet.")
            }
            if ["yuva", "rgba", "argb", "bgra", "abgr", "gbrap"].contains(where: { video.pix_fmt?.hasPrefix($0) == true }) {
                warnings.append("Video transparency needs an explicit background workflow that is not available yet.")
            }
            if ["smpte2084", "arib-std-b67"].contains(video.color_transfer ?? "") || (video.pix_fmt?.contains("10") ?? false) || (video.pix_fmt?.contains("12") ?? false) {
                warnings.append("HDR or high-bit-depth video requires a deliberate preservation or tone-mapping workflow that is not available yet.")
            }
            if (video.width ?? 0) > 8192 || (video.height ?? 0) > 8192 {
                throw FileformError(.resourceLimit, "This video exceeds the current 8192-pixel dimension limit.")
            }
        }
        let rotation = info.videos.first?.side_data_list?.compactMap(\.rotation).first ?? 0
        if rotation % 90 != 0 { warnings.append("This video's display rotation is not supported yet.") }
        return .init(input: input, identity: identity, family: .media, detectedType: info.format.format_name ?? "media",
                     width: info.videos.first?.width, height: info.videos.first?.height,
                     orientation: rotation, duration: duration, videoCodec: info.videos.first?.codec_name,
                     audioCodec: info.audios.first?.codec_name, audioStreams: info.audios.count,
                     audioSampleFormat: info.audios.first?.sample_fmt,
                     audioBitDepth: max(info.audios.first?.bits_per_sample ?? 0, info.audios.first?.bits_per_raw_sample.flatMap(Int.init) ?? 0),
                     warnings: warnings)
    }

    static func capabilities(for inspection: Inspection?, available: Bool) -> [Capability] {
        formats.filter { format in
            guard let inspection else { return true }
            if [.mp4, .mov].contains(format) { return inspection.videoCodec != nil }
            return inspection.audioCodec != nil
        }.map { .init(format: $0, goals: [.convert, .compress, .fit], engine: "ffmpeg", available: available,
                      limitation: available ? "Single-track SDR media; extra metadata is removed." : "Install the verified media engine pack.") }
    }

    func validate(_ inspection: Inspection, request: ConversionRequest) throws {
        let videoOutput = [.mp4, .mov].contains(request.format)
        if videoOutput && !inspection.warnings.isEmpty { throw FileformError(.unsupported, inspection.warnings[0]) }
        if !videoOutput && inspection.audioStreams != 1 {
            throw FileformError(.unsupported, "Choose an input with one audio track. Explicit selection between multiple tracks is not available yet.")
        }
        if request.format == .flac && ((inspection.audioCodec?.hasPrefix("pcm_f") ?? false) ||
                                       (inspection.audioBitDepth ?? 0) > 24) {
            throw FileformError(.unsupported, "This FLAC route cannot preserve floating-point or greater-than-24-bit audio. An explicit bit-depth conversion workflow is needed.")
        }
        let draft = ConversionPlan(request: request, inspection: inspection, engine: "ffmpeg", warnings: [])
        if videoOutput && !canRemux(draft) && request.options.maxDimension == nil &&
            ((inspection.width ?? 0) % 2 != 0 || (inspection.height ?? 0) % 2 != 0) {
            throw FileformError(.invalidRequest, "H.264 encoding needs even dimensions. Enable resizing and choose a longest edge; Fileform will not resize it silently.")
        }
        guard Self.formats.contains(request.format) else { throw FileformError(.unsupported, "This media output is not implemented.") }
        if [.mp4, .mov].contains(request.format) && inspection.videoCodec == nil {
            throw FileformError(.invalidRequest, "Choose an audio output for an audio-only input.")
        }
        if [.wav, .flac, .m4a].contains(request.format) && inspection.audioCodec == nil {
            throw FileformError(.invalidRequest, "This input has no audio track to extract.")
        }
        if request.options.background != nil { throw FileformError(.invalidRequest, "Background color is only valid for image conversion.") }
        if let dimension = request.options.maxDimension {
            guard [.mp4, .mov].contains(request.format), dimension >= 2 else {
                throw FileformError(.invalidRequest, "Media resizing needs a video output and a longest edge of at least two pixels.")
            }
        }
    }

    func canRemux(_ plan: ConversionPlan) -> Bool {
        [.mp4, .mov].contains(plan.request.format) && plan.request.goal == .convert &&
        plan.request.options.maxDimension == nil && plan.inspection.videoCodec == "h264" &&
        (plan.inspection.audioCodec == nil || plan.inspection.audioCodec == "aac")
    }

    func expectedDimensions(_ plan: ConversionPlan) -> (Int, Int)? {
        guard var width = plan.inspection.width, var height = plan.inspection.height else { return nil }
        if canRemux(plan) { return (width, height) }
        if abs(plan.inspection.orientation ?? 0) % 180 == 90 { swap(&width, &height) }
        if let bound = plan.request.options.maxDimension, max(width, height) > bound {
            let ratio = Double(bound) / Double(max(width, height))
            width = Int(Double(width) * ratio); height = Int(Double(height) * ratio)
        }
        return (max(2, width / 2 * 2), max(2, height / 2 * 2))
    }

    func encode(_ plan: ConversionPlan, destination: URL, attempt: Int) async throws {
        let request = plan.request
        let videoOutput = [.mp4, .mov].contains(request.format)
        let remux = canRemux(plan)
        var arguments = ["-hide_banner", "-nostdin", "-v", "error", "-nostats", "-xerror",
                         "-max_alloc", "268435456", "-protocol_whitelist", "file,pipe",
                         "-threads", "2", "-i", request.input.path, "-map_metadata", "-1", "-map_chapters", "-1"]
        if videoOutput { arguments += ["-map", "0:v:0", "-map", "0:a:0?"] }
        else { arguments += ["-map", "0:a:0", "-vn"] }
        let duration = plan.inspection.duration ?? 0
        var audioRate = 128_000
        var videoRate = 2_000_000
        if request.goal == .compress && videoOutput {
            let budget = Double(plan.inspection.identity.bytes) * 8 / max(duration, 0.01) * 0.65 - (plan.inspection.audioCodec != nil ? Double(audioRate) : 0)
            videoRate = Int(max(Double(request.options.minimumVideoBitrate), min(2_000_000, budget)))
        }
        if request.goal == .fit, let limit = request.options.maximumBytes {
            let budget = (Double(limit) - 16_384) * 8 / max(duration, 0.01) * 0.96 * pow(0.88, Double(attempt))
            if videoOutput {
                videoRate = Int(max(0, min(budget - (plan.inspection.audioCodec != nil ? Double(audioRate) : 0), Double(Int32.max))))
                guard videoRate >= request.options.minimumVideoBitrate else {
                    throw FileformError(.targetUnmet, "The byte limit cannot accommodate a complete video at the chosen minimum bitrate. Increase the limit or explicitly change your constraints.")
                }
            } else if request.format == .m4a {
                audioRate = Int(max(0, min(128_000, budget)))
                guard audioRate >= 48_000 else { throw FileformError(.targetUnmet, "The byte limit is too small for the complete recording at the minimum 48 kb/s audio bitrate.") }
            }
        }
        if remux { arguments += ["-c", "copy"] }
        else {
            if videoOutput {
                guard let (width, height) = expectedDimensions(plan) else { throw FileformError(.unsupported, "Video dimensions could not be established.") }
                arguments += ["-vf", "scale=\(width):\(height),setsar=1", "-c:v", "h264_videotoolbox",
                              "-allow_sw", "1", "-b:v", "\(videoRate)", "-pix_fmt", "yuv420p", "-filter_threads", "2"]
            }
            switch request.format {
            case .wav: arguments += ["-c:a", "pcm_s16le"]
            case .flac: arguments += ["-c:a", "flac", "-compression_level", "8"]
            default: arguments += ["-c:a", "aac", "-b:a", "\(audioRate)"]
            }
        }
        if [.mp4, .mov, .m4a].contains(request.format) { arguments += ["-movflags", "+faststart"] }
        arguments += ["-n", destination.path]
        let result = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: arguments,
                                                 timeout: min(12 * 3600, max(120, duration * 4 + 60)))
        guard result.status == 0 else { throw FileformError(.engineFailed, "Media encoding failed. The original is unchanged. Try a different output or inspect whether the input is damaged.") }
    }

    func verify(_ output: URL, plan: ConversionPlan) async throws -> Int64 {
        let info = try await probe(output)
        let source = try await probe(plan.request.input)
        let isVideo = [.mp4, .mov].contains(plan.request.format)
        let expectedDuration = (!isVideo ? source.audios.first?.duration.flatMap(Double.init) : nil) ?? plan.inspection.duration ?? 0
        guard let duration = info.format.duration.flatMap(Double.init), duration.isFinite,
              abs(duration - expectedDuration) <= 0.25 else {
            throw FileformError(.verificationFailed, "The output failed full-duration verification.")
        }
        if isVideo {
            guard info.videos.count == 1, info.videos[0].codec_name == "h264",
                  let (width, height) = expectedDimensions(plan), info.videos[0].width == width, info.videos[0].height == height,
                  info.audios.count == plan.inspection.audioStreams else {
                throw FileformError(.verificationFailed, "The output failed video dimension or stream verification.")
            }
        } else {
            guard info.videos.isEmpty, info.audios.count == 1 else { throw FileformError(.verificationFailed, "The output failed audio stream verification.") }
        }
        let expectedCodec: String = switch plan.request.format {
        case .wav: "pcm_s16le"; case .flac: "flac"; default: "aac"
        }
        if let audio = info.audios.first, audio.codec_name != expectedCodec {
            throw FileformError(.verificationFailed, "The audio codec does not match the requested output.")
        }
        if let audio = info.audios.first, let originalAudio = source.audios.first {
            guard audio.channels == originalAudio.channels, audio.sample_rate == originalAudio.sample_rate else {
                throw FileformError(.verificationFailed, "The output did not preserve the audio channel count and sample rate.")
            }
        }
        let containers = info.format.format_name?.split(separator: ",").map(String.init) ?? []
        let expectedContainer = switch plan.request.format { case .wav: "wav"; case .flac: "flac"; default: "mov" }
        guard containers.contains(expectedContainer) else { throw FileformError(.verificationFailed, "The media container does not match the selected output.") }
        let decoded = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-v", "error", "-xerror", "-err_detect", "explode",
            "-max_alloc", "268435456", "-protocol_whitelist", "file,pipe", "-threads", "2",
            "-i", output.path, "-map", "0:v?", "-map", "0:a?", "-f", "null", "-"
        ], timeout: min(12 * 3600, max(120, expectedDuration * 4 + 60)))
        guard decoded.status == 0 else { throw FileformError(.verificationFailed, "The complete output could not be decoded successfully.") }
        return try FileSafety.identity(output).bytes
    }
}

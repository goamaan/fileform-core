// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import ImageIO
import Testing
import FileformDomain
@testable import FileformCore

private let previewPack = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FILEFORM_MEDIA_PACK"] ??
    FileManager.default.currentDirectoryPath + "/Artifacts/MediaPack")

@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: previewPack.appendingPathComponent("manifest.json").path)))
struct MediaPreviewTests {
    @Test func waveformMeasuresSeparateChannelsAndCompleteSampleCoverage() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.wav(seconds: 1)
        var bytes = try Data(contentsOf: source)
        // Opposite stereo channels would disappear if implicitly downmixed.
        for offset in stride(from: 44, to: bytes.count, by: 4) {
            let value = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
            let opposite = UInt16(bitPattern: -value)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: opposite)
            bytes[offset + 3] = UInt8(truncatingIfNeeded: opposite >> 8)
        }
        try bytes.write(to: source)
        let service = MediaPreviewService(mediaPack: previewPack)
        let timeline = try await service.inspect(source)
        #expect(timeline.duration == MediaTime(ticks: 48_000, timescale: 48_000))
        #expect(timeline.audioTracks.count == 1 && timeline.audioTracks[0].channels == 2)
        #expect(timeline.audioTracks[0].decodedSamples == 48_000 && timeline.audioTracks[0].timelineCompatible)
        let waveform = try await service.waveform(for: timeline, bins: 32)
        #expect(waveform.buckets.count == 32)
        #expect(waveform.buckets.first?.interval.start.ticks == 0)
        #expect(waveform.buckets.last?.interval.end.ticks == 48_000)
        for bucket in waveform.buckets {
            #expect(bucket.minimum.count == 2 && bucket.maximum.count == 2)
            #expect(abs(bucket.maximum[0] - Float(12_000.0 / 32_768.0)) < 0.0001)
            #expect(abs(bucket.minimum[0] + bucket.maximum[1]) < 0.000001)
        }
        await #expect(throws: FileformError.self) { try await service.waveform(for: timeline, bins: 5000) }
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func previewLeaseIsVerifiedAndSourceChangesInvalidateTimeline() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.wav(seconds: 0.5)
        let original = try Data(contentsOf: source)
        let service = MediaPreviewService(mediaPack: previewPack)
        let timeline = try await service.inspect(source)
        let preview = try await service.playbackPreview(for: timeline)
        #expect(FileManager.default.fileExists(atPath: preview.url.path))
        let pack = try MediaPack(directory: previewPack)
        let info = try await MediaBackend(pack: pack).probe(preview.url)
        #expect(info.audios.count == 1 && info.videos.isEmpty)
        #expect(info.format.duration.flatMap(Double.init) == 0.5)
        let decoded = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: [
            "-v", "error", "-xerror", "-i", preview.url.path, "-f", "s16le", "-c:a", "pcm_s16le", "-"
        ])
        #expect(decoded.status == 0 && decoded.stdout == original.dropFirst(44))
        preview.discard(); preview.discard()
        #expect(!FileManager.default.fileExists(atPath: preview.url.path))
        #expect(try Data(contentsOf: source) == original)
        await #expect(throws: FileformError.self) { try await service.exportPlaybackPreview(for: timeline, destination: source) }
        let cancelled = Task { try await service.inspect(source) }; cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled inspection should not succeed") } catch is CancellationError {} catch { throw error }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 2)], ofItemAtPath: source.path)
        await #expect(throws: FileformError.self) { try await service.waveform(for: timeline) }
    }

    @Test func videoPosterAndSelectedAudioProxyUseMeasuredContent() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pack = try MediaPack(directory: previewPack)
        let raw = fixture.url("frames.rgb")
        var pixels = Data()
        for frame in 0..<20 {
            for _ in 0..<(128 * 96) { pixels.append(contentsOf: [UInt8(frame * 10), 50, 180]) }
        }
        try pixels.write(to: raw)
        let audio = try fixture.wav(seconds: 2), source = fixture.url("video.mp4"), silence = fixture.url("silence.wav")
        var silent = try Data(contentsOf: audio)
        silent.replaceSubrange(44..<silent.count, with: repeatElement(UInt8(0), count: silent.count - 44))
        try silent.write(to: silence)
        let created = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: [
            "-v", "error", "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "128x96", "-framerate", "10", "-i", raw.path,
            "-i", silence.path, "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0", "-c:v", "h264_videotoolbox", "-allow_sw", "1",
            "-b:v", "300000", "-bf", "0", "-g", "10", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path
        ])
        #expect(created.status == 0)
        let service = MediaPreviewService(mediaPack: previewPack), timeline = try await service.inspect(source)
        #expect(timeline.video?.frameCount == 20 && timeline.video?.constantFrameTiming == true)
        #expect(timeline.audioTracks.count == 2)
        await #expect(throws: FileformError.self) { try await service.waveform(for: timeline) }
        let poster = try await service.poster(for: timeline, at: .init(ticks: 125, timescale: 100), maximumDimension: 64)
        #expect(poster.width == 64 && poster.height == 48 && !poster.png.isEmpty)
        #expect(abs(MediaTimelineReader.seconds(poster.realizedTime) - 1.2) < 0.000001)
        let imageSource = try #require(CGImageSourceCreateWithData(poster.png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect((100...140).contains(Int(pixel[0])) && (30...70).contains(Int(pixel[1])) && (160...200).contains(Int(pixel[2])))
        let preview = try await service.playbackPreview(for: timeline, audioStream: 1, maximumDimension: 64)
        defer { preview.discard() }
        let output = try await MediaBackend(pack: pack).probe(preview.url)
        #expect(output.videos.first?.width == 64 && output.videos.first?.height == 48)
        #expect(output.audios.count == 1 && preview.audioStreamIndex == timeline.audioTracks[1].index)
        let pcm = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: ["-v", "error", "-i", preview.url.path, "-map", "0:a:0", "-f", "f32le", "-c:a", "pcm_f32le", "-"])
        #expect(pcm.status == 0)
        let power = pcm.stdout.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).reduce(0.0) { sum, offset in
                let sample = Double(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)); return sum + sample * sample
            } / Double(bytes.count / 4)
        }
        #expect(power > 0.03) // Track zero is silent; the selected track is not.
    }

    @Test func gappedAudioCannotBecomeAMisleadingWaveformOrProxy() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let input = try fixture.wav(seconds: 2), output = fixture.url("gap.m4a")
        let pack = try MediaPack(directory: previewPack)
        let process = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: [
            "-v", "error", "-i", input.path, "-af", "asetpts=PTS+gte(T\\,1)*0.25/TB", "-c:a", "aac", output.path
        ])
        #expect(process.status == 0)
        let service = MediaPreviewService(mediaPack: previewPack), timeline = try await service.inspect(output)
        #expect(timeline.audioTracks.first?.timelineCompatible == false)
        await #expect(throws: FileformError.self) { try await service.waveform(for: timeline) }
        await #expect(throws: FileformError.self) { try await service.playbackPreview(for: timeline) }
    }
}

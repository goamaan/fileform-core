// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Testing
import FileformDomain
@testable import FileformCore

private let trimPackURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FILEFORM_MEDIA_PACK"] ??
                             FileManager.default.currentDirectoryPath + "/Artifacts/MediaPack")

private func trimRequest(_ input: URL, output: URL, format: OutputFormat, start: MediaTime, end: MediaTime,
                          mode: TrimMode = .exact, audio: Int? = nil, collision: CollisionPolicy = .fail) throws -> TransformationRequest {
    try .init(assets: [.init(id: "recording", url: input)],
              operation: .mediaTrim(interval: .init(start: start, end: end), mode: mode, audioStream: audio),
              output: .init(destination: output, format: format), collisionPolicy: collision)
}
private func seconds(_ time: MediaTime) -> Double { Double(time.ticks) / Double(time.timescale) }
private func trimRun(_ pack: MediaPack, _ args: [String]) async throws -> Data {
    let result = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: ["-v", "error", "-nostdin"] + args)
    #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
    guard result.status == 0 else { throw FileformError(.engineFailed, "Synthetic trim fixture command failed.") }
    return result.stdout
}

private func markedVideo(_ fixture: Fixture, pack: MediaPack) async throws -> URL {
    var frames = Data()
    for frame in 0..<60 {
        let pixel: [UInt8] = [UInt8(frame * 4), UInt8(250 - frame * 3), UInt8(frame * 2)]
        for _ in 0..<(160 * 96) { frames.append(contentsOf: pixel) }
    }
    let raw = fixture.url("frame-markers.rgb")
    try frames.write(to: raw)
    let audio = try fixture.wav(seconds: 6)
    let output = fixture.url("marked.mp4")
    _ = try await trimRun(pack, ["-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "160x96", "-framerate", "10",
                                "-i", raw.path, "-i", audio.path, "-c:v", "h264_videotoolbox", "-allow_sw", "1",
                                "-b:v", "300000", "-g", "10", "-bf", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", output.path])
    return output
}

private func videoHashes(_ input: URL, pack: MediaPack) async throws -> [String] {
    let result = try await ProcessRunner.run(executable: pack.ffprobe, arguments: ["-v", "error", "-select_streams", "v:0",
        "-show_packets", "-show_entries", "packet=data_hash", "-show_data_hash", "sha256", "-of", "json", input.path])
    #expect(result.status == 0)
    struct Report: Decodable { struct Packet: Decodable { let data_hash: String }; let packets: [Packet] }
    return try JSONDecoder().decode(Report.self, from: result.stdout).packets.map(\.data_hash)
}

private func amplitudeAudio(_ fixture: Fixture) throws -> URL {
    let sampleRate = 48000, frames = sampleRate * 6
    var bytes = Data()
    func text(_ value: String) { bytes.append(contentsOf: value.utf8) }
    func integer<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }
    text("RIFF"); integer(UInt32(36 + frames * 2)); text("WAVEfmt "); integer(UInt32(16))
    integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(sampleRate)); integer(UInt32(sampleRate * 2))
    integer(UInt16(2)); integer(UInt16(16)); text("data"); integer(UInt32(frames * 2))
    for sample in 0..<frames { integer(Int16((sample / sampleRate + 1) * 1000)) }
    let output = fixture.url("amplitude-seconds.wav")
    try bytes.write(to: output)
    return output
}

private func middleAmplitude(_ pcm: Data) throws -> Int {
    #expect(pcm.count >= 2)
    guard pcm.count >= 2 else { throw FileformError(.verificationFailed, "Missing PCM oracle output.") }
    let offset = (pcm.count / 4) * 2
    return Int(Int16(bitPattern: UInt16(pcm[offset]) | UInt16(pcm[offset + 1]) << 8))
}

@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: trimPackURL.appendingPathComponent("manifest.json").path),
                            "Build the pinned media pack to run real trim integration tests."))
struct MediaTrimTests {
    @Test func exactAudioRejectsInteriorTimestampGapInsteadOfSelectingWrongAmplitude() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pack = try MediaPack(directory: trimPackURL)
        let pcm = try amplitudeAudio(fixture)
        let gap = fixture.url("gap.m4a")
        _ = try await trimRun(pack, ["-i", pcm.path, "-af", "asetpts=PTS+gte(T\\,2)*2/TB", "-c:a", "aac", gap.path])
        let before = SHA256.hash(data: try Data(contentsOf: gap))
        // Independent timestamp-based FFmpeg oracle: 4.2–4.8 seconds is the
        // source's third amplitude band after a two-second clock gap, not the
        // fifth band obtained by treating time as a decoded sample offset.
        let timestampOracle = try await trimRun(pack, ["-i", gap.path, "-af", "atrim=start=4.2:end=4.8,asetpts=PTS-STARTPTS",
                                                        "-c:a", "pcm_s16le", "-f", "s16le", "-"])
        let indexOracle = try await trimRun(pack, ["-i", gap.path, "-af", "atrim=start_sample=201600:end_sample=230400,asetpts=PTS-STARTPTS",
                                                    "-c:a", "pcm_s16le", "-f", "s16le", "-"])
        let timestampAmplitude = try middleAmplitude(timestampOracle)
        let indexAmplitude = try middleAmplitude(indexOracle)
        #expect(timestampOracle.count == 28800 * 2 && indexOracle.count == 28800 * 2)
        #expect(abs(timestampAmplitude - 3000) < 100)
        #expect(abs(indexAmplitude - 5000) < 100)
        let video = try await markedVideo(fixture, pack: pack)
        let withPicture = fixture.url("picture-and-gapped-audio.mp4")
        _ = try await trimRun(pack, ["-i", video.path, "-i", gap.path, "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", withPicture.path])
        let engine = ConversionEngine(mediaPack: trimPackURL)
        for (source, format) in [(gap, OutputFormat.wav), (withPicture, .mp4)] {
            let output = fixture.url("must-not-publish.\(format.fileExtension)")
            let request = try trimRequest(source, output: output, format: format,
                                          start: .init(ticks: 42, timescale: 10), end: .init(ticks: 48, timescale: 10))
            do { _ = try await engine.plan(request); Issue.record("Exact trim accepted a gapped audio clock and would select the wrong samples") }
            catch let failure as FileformError { #expect(failure.code == .unsupported) }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
        let after = SHA256.hash(data: try Data(contentsOf: gap))
        #expect(after == before)
    }

    @Test func exactAudioRejectsOverlappingTimestampsBeforeIndexingSamples() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pack = try MediaPack(directory: trimPackURL)
        let source = try amplitudeAudio(fixture)
        let overlap = fixture.url("overlap.m4a")
        _ = try await trimRun(pack, ["-i", source.path, "-af", "asetpts=PTS-gte(T\\,3)*0.5/TB", "-c:a", "aac", overlap.path])
        let timestampOracle = try await trimRun(pack, ["-i", overlap.path, "-af", "atrim=start=3.3:end=3.9,asetpts=PTS-STARTPTS",
                                                        "-c:a", "pcm_s16le", "-f", "s16le", "-"])
        let indexOracle = try await trimRun(pack, ["-i", overlap.path, "-af", "atrim=start_sample=158400:end_sample=187200,asetpts=PTS-STARTPTS",
                                                    "-c:a", "pcm_s16le", "-f", "s16le", "-"])
        let timestampAmplitude = try middleAmplitude(timestampOracle)
        let indexAmplitude = try middleAmplitude(indexOracle)
        #expect(timestampOracle.count == 28800 * 2 && indexOracle.count == 28800 * 2)
        #expect(abs(timestampAmplitude - 5000) < 100)
        #expect(abs(indexAmplitude - 4000) < 100)
        let destination = fixture.url("must-not-publish.wav")
        let request = try trimRequest(overlap, output: destination, format: .wav,
                                      start: .init(ticks: 33, timescale: 10), end: .init(ticks: 39, timescale: 10))
        let engine = ConversionEngine(mediaPack: trimPackURL)
        do { _ = try await engine.plan(request); Issue.record("Overlapping audio timestamps were accepted for sample indexing") }
        catch let failure as FileformError { #expect(failure.code == .unsupported) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func exactPcmTrimRetainsEverySelectedSample() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let input = try fixture.wav(seconds: 6)
        let original = try Data(contentsOf: input)
        let pack = try MediaPack(directory: trimPackURL)
        let engine = ConversionEngine(mediaPack: trimPackURL)
        for format in [OutputFormat.wav, .flac] {
            let request = try trimRequest(input, output: fixture.url("trim.\(format.fileExtension)"), format: format,
                                          start: .init(ticks: 48001, timescale: 48000), end: .init(ticks: 144013, timescale: 48000))
            let plan = try await engine.plan(request)
            let result = try await engine.run(plan)
            let output = try #require(result.artifacts.first).url
            let decoded = try await trimRun(pack, ["-i", output.path, "-map", "0:a:0", "-c:a", "pcm_s16le", "-f", "s16le", "-"])
            // The fixture is stereo PCM16 with a standard 44-byte WAV header.
            #expect(decoded == original.subdata(in: (44 + 48001 * 4)..<(44 + 144013 * 4)))
            let details = try #require(result.mediaTrim)
            let outputDuration = try #require(details.outputDuration)
            #expect(details.realized == details.requested && !details.copiedStreams)
            #expect(details.audioStreamIndex == 0 && details.videoStreamIndex == nil)
            #expect(abs(seconds(outputDuration) - Double(144013 - 48001) / 48000) < 0.000022)
        }
        let retainedInput = try Data(contentsOf: input)
        #expect(retainedInput == original)
    }

    @Test func exactVideoTrimKeepsFrameMarkersAndAudioInSync() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pack = try MediaPack(directory: trimPackURL)
        let input = try await markedVideo(fixture, pack: pack)
        let before = SHA256.hash(data: try Data(contentsOf: input))
        let engine = ConversionEngine(mediaPack: trimPackURL)
        let request = try trimRequest(input, output: fixture.url("exact.mp4"), format: .mp4,
                                      start: .init(ticks: 135, timescale: 100), end: .init(ticks: 357, timescale: 100))
        let plan = try await engine.plan(request)
        let plannedDetails = try #require(plan.mediaTrim)
        #expect(abs(seconds(plannedDetails.realized.start) - 1.4) < 0.000001)
        #expect(abs(seconds(plannedDetails.realized.end) - 3.6) < 0.000001)
        let result = try await engine.run(plan)
        let output = try #require(result.artifacts.first).url
        let colors = [UInt8](try await trimRun(pack, ["-i", output.path, "-map", "0:v:0", "-vf", "scale=1:1",
                                                     "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]))
        #expect(colors.count == 22 * 3)
        for frame in 0..<22 {
            let sourceFrame = frame + 14
            let expected = [sourceFrame * 4, 250 - sourceFrame * 3, sourceFrame * 2]
            for channel in 0..<3 { #expect(abs(Int(colors[frame * 3 + channel]) - expected[channel]) <= 12) }
        }
        let audio = try await trimRun(pack, ["-i", output.path, "-map", "0:a:0", "-c:a", "pcm_s16le", "-f", "s16le", "-"])
        // AAC may retain at most one codec frame of end padding. The leading
        // waveform must align with the same 1.4-second boundary as the picture.
        #expect(abs(audio.count / 4 - 105600) <= 1024)
        var totalError = 0.0
        for sample in 2000..<8000 {
            let offset = sample * 4
            let actual = Int16(bitPattern: UInt16(audio[offset]) | UInt16(audio[offset + 1]) << 8)
            let expected = sin(Double(sample + 67200) / 48000 * 440 * 2 * .pi) * 12000
            totalError += abs(Double(actual) - expected)
        }
        #expect(totalError / 6000 < 1600, "Trimmed audio must retain its source phase relative to the picture.")
        let after = SHA256.hash(data: try Data(contentsOf: input))
        #expect(after == before)
    }

    @Test func fastVideoTrimSnapsToKeyframesAndCopiesOriginalPackets() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pack = try MediaPack(directory: trimPackURL)
        let input = try await markedVideo(fixture, pack: pack)
        let engine = ConversionEngine(mediaPack: trimPackURL)
        let request = try trimRequest(input, output: fixture.url("fast.mp4"), format: .mp4,
                                      start: .init(ticks: 135, timescale: 100), end: .init(ticks: 357, timescale: 100), mode: .copy)
        let plan = try await engine.plan(request)
        let measured = try #require(plan.mediaTrim)
        #expect(seconds(measured.realized.start) == 1 && seconds(measured.realized.end) == 4)
        #expect(measured.copiedStreams && measured.videoStreamIndex == 0 && measured.audioStreamIndex == 1)
        let result = try await engine.run(plan)
        let output = try #require(result.artifacts.first).url
        let sourceHashes = try await videoHashes(input, pack: pack)
        let outputHashes = try await videoHashes(output, pack: pack)
        #expect(outputHashes == Array(sourceHashes[10..<40]))
        let details = try #require(result.mediaTrim)
        let outputDuration = try #require(details.outputDuration)
        #expect(abs(seconds(outputDuration) - 3) <= seconds(details.durationTolerance) + 0.001)
        let nextRequest = try trimRequest(input, output: fixture.url("forged.mp4"), format: .mp4,
                                          start: measured.requested.start, end: measured.requested.end, mode: .copy)
        let forged = MediaTrimDetails(requested: measured.requested,
            realized: .init(start: .init(ticks: 0, timescale: 1), end: .init(ticks: 2, timescale: 1)), mode: .copy,
            videoStreamIndex: measured.videoStreamIndex, audioStreamIndex: measured.audioStreamIndex,
            copiedStreams: true, durationTolerance: measured.durationTolerance)
        let invalidPlan = TransformationPlan(request: nextRequest, inputs: plan.inputs, warnings: [], mediaTrim: forged)
        do { _ = try await engine.run(invalidPlan); Issue.record("Forged snapped interval executed") }
        catch let failure as FileformError { #expect(failure.code == .inputChanged) }
        #expect(!FileManager.default.fileExists(atPath: fixture.url("forged.mp4").path))
    }

    @Test func fastAudioExtractionUsesAudioBoundariesInsteadOfPictureGops() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pack = try MediaPack(directory: trimPackURL)
        let input = try await markedVideo(fixture, pack: pack)
        let engine = ConversionEngine(mediaPack: trimPackURL)
        let request = try trimRequest(input, output: fixture.url("fast.m4a"), format: .m4a,
                                      start: .init(ticks: 135, timescale: 100), end: .init(ticks: 357, timescale: 100), mode: .copy)
        let plan = try await engine.plan(request)
        let details = try #require(plan.mediaTrim)
        #expect(abs(seconds(details.realized.start) - 1.344) < 0.000001)
        #expect(abs(seconds(details.realized.end) - 3.584) < 0.000001)
        let result = try await engine.run(plan)
        let outputDuration = try #require(result.mediaTrim?.outputDuration)
        #expect(result.status == .succeeded)
        #expect(result.mediaTrim?.audioStreamIndex == 1 && result.mediaTrim?.videoStreamIndex == nil)
        #expect(abs(seconds(outputDuration) - 2.24) < 0.001)
    }

    @Test func invalidRangesAndUnselectedMultipleStreamsFailBeforePublication() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pack = try MediaPack(directory: trimPackURL)
        let input = try await markedVideo(fixture, pack: pack)
        let engine = ConversionEngine(mediaPack: trimPackURL)
        for end in [7, Int64.max] {
            let request = try trimRequest(input, output: fixture.url("invalid.mp4"), format: .mp4,
                                          start: .init(ticks: 1, timescale: 1), end: .init(ticks: end, timescale: 1))
            await #expect(throws: FileformError.self) { try await engine.plan(request) }
        }
        let multi = fixture.url("two-audio.mp4")
        _ = try await trimRun(pack, ["-i", input.path, "-map", "0:v:0", "-map", "0:a:0", "-map", "0:a:0", "-c", "copy", multi.path])
        let ambiguous = try trimRequest(multi, output: fixture.url("ambiguous.wav"), format: .wav,
                                        start: .init(ticks: 1, timescale: 1), end: .init(ticks: 2, timescale: 1))
        do { _ = try await engine.plan(ambiguous); Issue.record("Multiple audio tracks were silently selected") }
        catch let failure as FileformError { #expect(failure.code == .invalidRequest) }
        let selected = try trimRequest(multi, output: fixture.url("selected.wav"), format: .wav,
                                       start: .init(ticks: 1, timescale: 1), end: .init(ticks: 2, timescale: 1), audio: 1)
        let selectedPlan = try await engine.plan(selected)
        #expect(selectedPlan.mediaTrim?.audioStreamIndex == 2)
        let selectedResult = try await engine.run(selectedPlan)
        #expect(selectedResult.status == .succeeded)
        for (format, audio) in [(OutputFormat.mp3, 0), (.wav, 99)] {
            let request = try trimRequest(multi, output: fixture.url("unavailable"), format: format,
                                          start: .init(ticks: 1, timescale: 1), end: .init(ticks: 2, timescale: 1), audio: audio)
            await #expect(throws: FileformError.self) { try await engine.plan(request) }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.url("invalid.mp4").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("ambiguous.wav").path))
    }

    @Test func trimRejectsAliasesChangedSourcesAndCancellationWithoutClobbering() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let input = try fixture.wav(seconds: 6)
        let before = try Data(contentsOf: input)
        let engine = ConversionEngine(mediaPack: trimPackURL)
        let alias = fixture.url("alias.wav")
        try FileManager.default.linkItem(at: input, to: alias)
        let aliased = try trimRequest(input, output: alias, format: .wav,
                                     start: .init(ticks: 1, timescale: 1), end: .init(ticks: 2, timescale: 1), collision: .rename)
        await #expect(throws: FileformError.self) { try await engine.plan(aliased) }
        let destination = fixture.url("racing.wav")
        let request = try trimRequest(input, output: destination, format: .wav,
                                      start: .init(ticks: 1, timescale: 1), end: .init(ticks: 2, timescale: 1))
        let plan = try await engine.plan(request)
        let other = Data("another writer".utf8)
        do {
            _ = try await engine.run(plan) { event in
                if event.phase == .saving { try? other.write(to: destination, options: .withoutOverwriting) }
            }
            Issue.record("Racing destination was overwritten")
        } catch let failure as FileformError { #expect(failure.code == .destinationExists) }
        let retainedDestination = try Data(contentsOf: destination)
        #expect(retainedDestination == other)
        let cancelledRequest = try trimRequest(input, output: fixture.url("cancelled.wav"), format: .wav,
                                               start: .init(ticks: 1, timescale: 1), end: .init(ticks: 2, timescale: 1))
        let cancelledPlan = try await engine.plan(cancelledRequest)
        let task = Task {
            try await engine.run(cancelledPlan) { event in
                // A fully encoded candidate exists before cancellation. It must
                // still be discarded rather than escaping as a successful trim.
                if event.phase == .verifying { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let retainedInput = try Data(contentsOf: input)
        #expect(retainedInput == before)
        try Data("changed".utf8).write(to: input)
        do { _ = try await engine.run(cancelledPlan); Issue.record("Changed source was accepted") }
        catch let failure as FileformError { #expect(failure.code == .inputChanged) }
        #expect(!FileManager.default.fileExists(atPath: fixture.url("cancelled.wav").path))
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(remainingFiles.allSatisfy { !$0.hasPrefix(".fileform-") })
    }

    @Test func unsupportedPictureTimelinesFailAndSharedNonzeroOriginIsMeasured() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pack = try MediaPack(directory: trimPackURL)
        let input = try await markedVideo(fixture, pack: pack)
        let engine = ConversionEngine(mediaPack: trimPackURL)
        let subtitles = fixture.url("subtitle.srt")
        try Data("1\n00:00:01,000 --> 00:00:02,000\nSynthetic subtitle\n".utf8).write(to: subtitles)
        let withSubtitle = fixture.url("subtitled.mp4")
        _ = try await trimRun(pack, ["-i", input.path, "-i", subtitles.path, "-map", "0", "-map", "1:0",
                                    "-c", "copy", "-c:s", "mov_text", withSubtitle.path])
        let variable = fixture.url("variable.mp4")
        _ = try await trimRun(pack, ["-i", input.path, "-map", "0:v:0", "-vf", "setpts='if(lt(N,30),N,N+1)/(10*TB)'",
                                    "-fps_mode", "vfr", "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-bf", "0", variable.path])
        for source in [withSubtitle, variable] {
            let request = try trimRequest(source, output: fixture.url("unsupported.mp4"), format: .mp4,
                                          start: .init(ticks: 1, timescale: 1), end: .init(ticks: 2, timescale: 1))
            do { _ = try await engine.plan(request); Issue.record("Unsupported picture timeline was accepted") }
            catch let failure as FileformError { #expect(failure.code == .unsupported) }
        }
        let shifted = fixture.url("shifted.mp4")
        _ = try await trimRun(pack, ["-i", input.path, "-map", "0:v:0", "-c", "copy", "-output_ts_offset", "5", shifted.path])
        let probe = try await MediaBackend(pack: pack).probe(shifted)
        #expect(probe.format.start_time.flatMap(Double.init) == 5)
        for mode in [TrimMode.exact, .copy] {
            let request = try trimRequest(shifted, output: fixture.url("shifted-\(mode.rawValue).mp4"), format: .mp4,
                                          start: .init(ticks: 1, timescale: 1), end: .init(ticks: 3, timescale: 1), mode: mode)
            let plan = try await engine.plan(request)
            let plannedDetails = try #require(plan.mediaTrim)
            #expect(seconds(plannedDetails.realized.start) == 1)
            let result = try await engine.run(plan)
            let outputDuration = try #require(result.mediaTrim?.outputDuration)
            #expect(abs(seconds(outputDuration) - 2) <= 0.001)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.url("unsupported.mp4").path))
    }
}

@Test func legacyTransformationRecordsDecodeWithoutTrimMeasurements() throws {
    let request = try TransformationRequest(assets: [.init(id: "source", url: URL(fileURLWithPath: "/tmp/input.png"))],
                                           operation: .conversion(.init()), output: .init(destination: URL(fileURLWithPath: "/tmp/output.png"), format: .png))
    let plan = TransformationPlan(request: request, inputs: [], warnings: [])
    let result = TransformationResult(operationID: .conversion, status: .notSmaller, artifacts: [], warnings: [], attempts: 1)
    let encodedPlan = try JSONEncoder().encode(plan)
    let decodedPlan = try JSONDecoder().decode(TransformationPlan.self, from: encodedPlan)
    let encodedResult = try JSONEncoder().encode(result)
    let decodedResult = try JSONDecoder().decode(TransformationResult.self, from: encodedResult)
    #expect(decodedPlan.mediaTrim == nil)
    #expect(decodedResult.mediaTrim == nil)
}

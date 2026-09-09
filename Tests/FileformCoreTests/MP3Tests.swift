// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import FileformDomain
@testable import FileformCore

private let mp3PackURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FILEFORM_MEDIA_PACK"] ??
                            FileManager.default.currentDirectoryPath + "/Artifacts/MediaPack")

@Suite(.enabled(if: (try? MediaPack(directory: mp3PackURL).supportsMP3Encoding) == true,
               "Build the pinned MP3-enabled media pack to run MP3 integration tests."))
struct MP3Tests {
    @Test(arguments: [32_000, 44_100, 48_000])
    func conversionDecodesIndependentlyAndPreservesOriginal(sampleRate: Int) async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let wave = try fixture.wav(seconds: 2.137)
        let pack = try MediaPack(directory: mp3PackURL)
        let source = fixture.url("tagged.wav")
        let channels = sampleRate == 32_000 ? 1 : 2
        let tagged = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: ["-v", "error", "-i", wave.path,
            "-ar", "\(sampleRate)", "-ac", "\(channels)", "-metadata", "title=Private source title", source.path])
        #expect(tagged.status == 0)
        let original = try Data(contentsOf: source)
        let output = fixture.url("converted.mp3")
        let engine = ConversionEngine(mediaPack: mp3PackURL)
        let plan = try await engine.plan(.init(input: source, destination: output, format: .mp3))
        #expect(plan.warnings.contains { $0.contains("MP3 is lossy") })
        let result = try await engine.run(plan)
        #expect(result.status == .succeeded)
        let probe = try await MediaBackend(pack: pack).probe(output)
        #expect(probe.format.format_name == "mp3")
        #expect(probe.audios.count == 1 && probe.audios[0].codec_name == "mp3")
        #expect(probe.audios[0].channels == channels && probe.audios[0].sample_rate == "\(sampleRate)")
        #expect(probe.format.tags == nil || probe.format.tags?.isEmpty == true)
        // Apple's decoder provides an independent implementation, outside FFmpeg/LAME.
        let decoded = fixture.url("decoded.wav")
        let decode = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/afconvert"),
            arguments: ["-f", "WAVE", "-d", "LEI16", output.path, decoded.path])
        #expect(decode.status == 0, "\(String(decoding: decode.stderr, as: UTF8.self))")
        let pcm = try await MediaBackend(pack: pack).probe(decoded)
        #expect(pcm.audios[0].sample_rate == "\(sampleRate)" && pcm.audios[0].channels == channels)
        #expect(abs(try #require(pcm.format.duration.flatMap(Double.init)) - 2.137) < 0.06)
        let gapless = fixture.url("gapless.wav")
        let decodedGapless = try await ProcessRunner.run(executable: pack.ffmpeg,
            arguments: ["-v", "error", "-i", output.path, "-c:a", "pcm_s16le", gapless.path])
        #expect(decodedGapless.status == 0)
        let gaplessProbe = try await MediaBackend(pack: pack).probe(gapless)
        let sourceProbe = try await MediaBackend(pack: pack).probe(source)
        #expect(gaplessProbe.audios[0].duration_ts == sourceProbe.audios[0].duration_ts)
        #expect(try Data(contentsOf: source) == original)
        #expect(try #require(result.outputBytes) < original.count)
        let inventory = await engine.capabilityInventory()
        #expect(inventory.routes.contains { $0.operationID == .conversion && $0.outputFormat == .mp3 && $0.available })
        #expect(!inventory.routes.contains { $0.operationID == .mediaTrim && $0.outputFormat == .mp3 })
    }

    @Test func fitHonorsBudgetAndImpossibleBudgetDoesNotPublish() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.wav(seconds: 8)
        let engine = ConversionEngine(mediaPack: mp3PackURL)
        let plan = try await engine.plan(.init(input: source, destination: fixture.url("fit.mp3"), format: .mp3,
                                              goal: .fit, options: .init(maximumBytes: 110_000)))
        let result = try await engine.run(plan)
        #expect(result.status == .succeeded && (result.outputBytes ?? .max) <= 110_000)
        let impossible = fixture.url("impossible.mp3")
        let rejected = try await engine.plan(.init(input: source, destination: impossible, format: .mp3,
                                                  goal: .fit, options: .init(maximumBytes: 20)))
        do { _ = try await engine.run(rejected); Issue.record("Expected target_unmet") }
        catch let error as FileformError { #expect(error.code == .targetUnmet) }
        #expect(!FileManager.default.fileExists(atPath: impossible.path))
    }

    @Test func oldPackDoesNotAdvertiseMP3AndUnsupportedSampleRateFailsAtPlanning() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let legacy = fixture.url("LegacyPack")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: legacy.appendingPathComponent("bin"), withDestinationURL: mp3PackURL.appendingPathComponent("bin"))
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: mp3PackURL.appendingPathComponent("manifest.json"))) as? [String: Any])
        manifest.removeValue(forKey: "audioEncoders")
        try JSONSerialization.data(withJSONObject: manifest).write(to: legacy.appendingPathComponent("manifest.json"))
        let old = ConversionEngine(mediaPack: legacy)
        #expect(await old.capabilities().contains { $0.format == .mp3 && !$0.available })
        let source = try fixture.wav()
        await #expect(throws: FileformError.self) { try await old.plan(.init(input: source, destination: fixture.url("old.mp3"), format: .mp3)) }
        let pack = try MediaPack(directory: mp3PackURL)
        let highRate = fixture.url("96k.wav")
        let created = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: ["-v", "error", "-i", source.path, "-ar", "96000", highRate.path])
        #expect(created.status == 0)
        let engine = ConversionEngine(mediaPack: mp3PackURL)
        await #expect(throws: FileformError.self) { try await engine.plan(.init(input: highRate, destination: fixture.url("high.mp3"), format: .mp3)) }
    }
}

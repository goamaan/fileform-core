// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import FileformDomain
@testable import FileformCore

private let packURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FILEFORM_MEDIA_PACK"] ??
                         FileManager.default.currentDirectoryPath + "/Artifacts/MediaPack")

extension Fixture {
    func wav(seconds: Double = 2) throws -> URL {
        let sampleRate = 48_000
        let frames = Int(Double(sampleRate) * seconds)
        var data = Data()
        func text(_ text: String) { data.append(contentsOf: text.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); integer(UInt32(36 + frames * 4)); text("WAVEfmt "); integer(UInt32(16))
        integer(UInt16(1)); integer(UInt16(2)); integer(UInt32(sampleRate)); integer(UInt32(sampleRate * 4))
        integer(UInt16(4)); integer(UInt16(16)); text("data"); integer(UInt32(frames * 4))
        for index in 0..<frames {
            let sample = Int16(sin(Double(index) / Double(sampleRate) * 440 * 2 * .pi) * 12_000)
            integer(sample); integer(sample)
        }
        let output = url("recording.wav"); try data.write(to: output); return output
    }
}

@Suite(.enabled(if: FileManager.default.fileExists(atPath: packURL.appendingPathComponent("manifest.json").path),
               "Build the pinned media pack with Tools/build-media-pack.sh to run media integration tests."))
struct MediaTests {
    @Test func damagedImageCannotBecomeReadyAsZeroDimensionVideo() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let input = fixture.url("damaged.png")
        try Data("not an image\n".utf8).write(to: input)
        let engine = ConversionEngine(mediaPack: packURL)
        await #expect(throws: FileformError.self) { try await engine.inspect(input) }
    }

    @Test func audioRoundTripIsComplete() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let input = try fixture.wav()
        let original = try Data(contentsOf: input)
        let engine = ConversionEngine(mediaPack: packURL)
        let flac = try await engine.plan(.init(input: input, destination: fixture.url("out.flac"), format: .flac))
        let result = try await engine.run(flac)
        #expect(result.status == .succeeded)
        #expect(try #require(result.outputBytes) < original.count)
        let m4a = try await engine.plan(.init(input: #require(result.output), destination: fixture.url("out.m4a"), format: .m4a))
        #expect(try await engine.run(m4a).status == .succeeded)
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func matroskaRemuxPreservesVideoAndAudio() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let image = try fixture.image()
        let audio = try fixture.wav()
        let pack = try MediaPack(directory: packURL)
        let created = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: [
            "-v", "error", "-loop", "1", "-framerate", "24", "-i", image.path, "-i", audio.path,
            "-t", "2", "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "500k",
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-f", "matroska", fixture.url("input.mkv").path
        ])
        #expect(created.status == 0, "\(String(decoding: created.stderr, as: UTF8.self))")
        let engine = ConversionEngine(mediaPack: packURL)
        let plan = try await engine.plan(.init(input: fixture.url("input.mkv"), destination: fixture.url("output.mp4"), format: .mp4))
        #expect(plan.warnings.contains { $0.contains("without re-encoding") })
        let result = try await engine.run(plan)
        let probe = try await engine.inspect(#require(result.output))
        #expect(probe.videoCodec == "h264" && probe.audioCodec == "aac")
        #expect(abs(try #require(probe.duration) - 2) < 0.25)
        let audioPlan = try await engine.plan(.init(input: fixture.url("input.mkv"), destination: fixture.url("extracted.flac"), format: .flac))
        #expect(try await engine.run(audioPlan).status == .succeeded)
        let fit = try await engine.plan(.init(input: fixture.url("input.mkv"), destination: fixture.url("fit.mp4"), format: .mp4,
                                              goal: .fit, options: .init(maximumBytes: 200_000)))
        let fitted = try await engine.run(fit)
        #expect(try #require(fitted.outputBytes) <= 200_000)
    }

    @Test func webmAudioExtractsToWav() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let audio = try fixture.wav()
        let pack = try MediaPack(directory: packURL)
        let created = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: [
            "-v", "error", "-i", audio.path, "-c:a", "opus", "-strict", "-2", fixture.url("input.webm").path
        ])
        #expect(created.status == 0, "\(String(decoding: created.stderr, as: UTF8.self))")
        let engine = ConversionEngine(mediaPack: packURL)
        let plan = try await engine.plan(.init(input: fixture.url("input.webm"), destination: fixture.url("output.wav"), format: .wav))
        #expect(try await engine.run(plan).status == .succeeded)
    }

    @Test func impossibleAudioBudgetDoesNotPublish() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let input = try fixture.wav()
        let engine = ConversionEngine(mediaPack: packURL)
        let plan = try await engine.plan(.init(input: input, destination: fixture.url("out.m4a"), format: .m4a,
                                              goal: .fit, options: .init(maximumBytes: 20)))
        do { _ = try await engine.run(plan); Issue.record("Expected target_unmet") }
        catch let error as FileformError { #expect(error.code == .targetUnmet) }
        #expect(!FileManager.default.fileExists(atPath: fixture.url("out.m4a").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".fileform-") })
    }
}

@Test func processTimeoutAndCancellationTerminateChild() async throws {
    do {
        _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
        Issue.record("Expected timeout")
    } catch let error as FileformError { #expect(error.code == .resourceLimit) }
    let task = Task { try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

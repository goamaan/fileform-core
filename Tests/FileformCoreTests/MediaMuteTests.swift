// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Testing
import FileformDomain
@testable import FileformCore

private let mutePackURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FILEFORM_MEDIA_PACK"] ??
                             FileManager.default.currentDirectoryPath + "/Artifacts/MediaPack")

private func muteRequest(input: URL, output: URL, mode: TrimMode = .exact, format: OutputFormat = .mp4,
                         audio: Int? = nil, muted: Bool = true) throws -> TransformationRequest {
    try .init(assets: [.init(id: "source", url: input)],
        operation: .mediaTrim(interval: .init(start: .init(ticks: 12, timescale: 10), end: .init(ticks: 26, timescale: 10)),
                              mode: mode, audioStream: audio, muteAudio: muted),
        output: .init(destination: output, format: format))
}

@Test func muteRejectsAudioOutputsAndConflictingSelection() throws {
    let input = URL(fileURLWithPath: "/tmp/input.mp4"), output = URL(fileURLWithPath: "/tmp/output.mp4")
    for format in [OutputFormat.m4a, .wav, .flac, .mp3] {
        #expect(throws: FileformError.self) { try muteRequest(input: input, output: output, format: format) }
    }
    #expect(throws: FileformError.self) { try muteRequest(input: input, output: output, audio: 0) }
    _ = try muteRequest(input: input, output: output, audio: 0, muted: false)
}

@Test func mutePreservesLegacyV1RequestAndRecipeAudioSemantics() throws {
    let request = try muteRequest(input: URL(fileURLWithPath: "/tmp/input.mp4"), output: URL(fileURLWithPath: "/tmp/out.mp4"))
    let recipe = try TransformationRecipe(name: "Silent clip", request: request)
    for original in [try JSONEncoder().encode(request), try JSONEncoder().encode(recipe)] {
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var operation = try #require(object["operation"] as? [String: Any])
        var parameters = try #require(operation["mediaTrimMuted"] as? [String: Any])
        #expect(parameters["muteAudio"] == nil)
        operation.removeValue(forKey: "mediaTrimMuted")
        operation["mediaTrim"] = parameters; object["operation"] = operation
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded: TransformationOperation
        if object["assetSlots"] != nil {
            let setup = try JSONDecoder().decode(TransformationRecipe.self, from: legacy)
            decoded = setup.operation
            let rebound = try setup.bind(assets: request.assets, destination: request.output.destination)
            #expect(rebound.operation == decoded)
        } else { decoded = try JSONDecoder().decode(TransformationRequest.self, from: legacy).operation }
        guard case .mediaTrim(_, _, let audio, let mute) = decoded else { Issue.record("Wrong operation"); continue }
        #expect(audio == nil && mute == false)
    }
    let roundtrip = try JSONDecoder().decode(TransformationRecipe.self, from: JSONEncoder().encode(recipe))
    #expect(roundtrip.operation == request.operation)
    let legacyCall = TransformationOperation.mediaTrim(interval: .init(start: .init(ticks: 0, timescale: 1), end: .init(ticks: 1, timescale: 1)), mode: .exact, audioStream: nil)
    guard case .mediaTrim(_, _, let audio, let mute) = legacyCall else { Issue.record("Wrong operation"); return }
    #expect(audio == nil && !mute)
    var invalid = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    var operation = try #require(invalid["operation"] as? [String: Any])
    var parameters = try #require(operation["mediaTrimMuted"] as? [String: Any])
    parameters["audioStream"] = 1; operation["mediaTrimMuted"] = parameters; invalid["operation"] = operation
    let invalidData = try JSONSerialization.data(withJSONObject: invalid)
    #expect(throws: FileformError.self) { try JSONDecoder().decode(TransformationRequest.self, from: invalidData) }
}

@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: mutePackURL.appendingPathComponent("manifest.json").path),
                            "Build the pinned media pack to verify native mute execution."))
struct MediaMuteTests {
    @Test func explicitMuteOmitsEveryAudioTrackInExactAndCopyOutputs() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pack = try MediaPack(directory: mutePackURL)
        let rgb = fixture.url("frames.rgb")
        var pixels = Data()
        for frame in 0..<40 {
            for _ in 0..<(64 * 48) { pixels.append(contentsOf: [UInt8(frame * 5), UInt8(200 - frame * 3), 90]) }
        }
        try pixels.write(to: rgb)
        let audio = try fixture.wav(seconds: 4)
        let source = fixture.url("two-track.mp4")
        let created = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "64x48", "-framerate", "10",
            "-i", rgb.path, "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0", "-map", "1:a:0",
            "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "300000", "-bf", "0", "-g", "10",
            "-pix_fmt", "yuv420p", "-c:a", "aac", source.path
        ])
        #expect(created.status == 0)
        let probe = MediaBackend(pack: pack)
        #expect(try await probe.probe(source).audios.count == 2)
        let original = SHA256.hash(data: try Data(contentsOf: source))
        let engine = ConversionEngine(mediaPack: mutePackURL)
        let ambiguous = try muteRequest(input: source, output: fixture.url("ambiguous.mp4"), muted: false)
        await #expect(throws: FileformError.self) { try await engine.plan(ambiguous) }
        for mode in [TrimMode.exact, .copy] {
            let request = try muteRequest(input: source, output: fixture.url("silent-\(mode.rawValue).mp4"), mode: mode)
            let plan = try await engine.plan(request)
            #expect(plan.mediaTrim?.audioStreamIndex == nil)
            #expect(plan.warnings.contains(where: { $0.contains("explicitly muted") }))
            let result = try await engine.run(plan)
            #expect(result.status == .succeeded)
            let output = try #require(result.artifacts.first).url
            let inspected = try await probe.probe(output)
            #expect(inspected.audios.isEmpty && inspected.videos.count == 1)
            #expect(result.mediaTrim?.audioStreamIndex == nil)
            #expect(result.mediaTrim?.copiedStreams == (mode == .copy))
            let expectedDuration = mode == .exact ? 1.4 : 2.0
            #expect(abs((inspected.format.duration.flatMap(Double.init) ?? 0) - expectedDuration) <= 0.001)
            let decoded = try await ProcessRunner.run(executable: pack.ffmpeg, arguments: [
                "-v", "error", "-nostdin", "-xerror", "-i", output.path, "-map", "0:v:0", "-f", "null", "-"
            ])
            #expect(decoded.status == 0)
        }
        #expect(SHA256.hash(data: try Data(contentsOf: source)) == original)
    }
}

private enum OldTrimOperation: Codable {
    case mediaTrim(interval: MediaInterval, mode: TrimMode, audioStream: Int?)
}
private struct OldTrimRecipe: Decodable { let schemaVersion: Int; let operation: OldTrimOperation }

@Test func mutedWireTagFailsClosedForOldClientsAndRejectsConflictingFlags() throws {
    let input = URL(fileURLWithPath: "/tmp/input.mp4"), output = URL(fileURLWithPath: "/tmp/output.mp4")
    let muted = try muteRequest(input: input, output: output)
    let recipe = try TransformationRecipe(name: "Muted", request: muted)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(OldTrimRecipe.self, from: JSONEncoder().encode(recipe)) }
    let unmuted = try muteRequest(input: input, output: output, muted: false)
    let oldRecipe = try JSONDecoder().decode(OldTrimRecipe.self, from: JSONEncoder().encode(TransformationRecipe(name: "Automatic audio", request: unmuted)))
    #expect(oldRecipe.schemaVersion == 1)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(unmuted.operation) == encoder.encode(oldRecipe.operation))
    var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(unmuted.operation)) as? [String: Any])
    var parameters = try #require(object["mediaTrim"] as? [String: Any])
    parameters["muteAudio"] = true; object["mediaTrim"] = parameters
    let malformed = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(TransformationOperation.self, from: malformed) }
}

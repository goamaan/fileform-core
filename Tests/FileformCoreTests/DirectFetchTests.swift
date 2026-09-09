// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import CryptoKit
import FileformDomain
@testable import FileformCore

private let fetchPack = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FILEFORM_MEDIA_PACK"] ??
    FileManager.default.currentDirectoryPath + "/Artifacts/MediaPack")

@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: fetchPack.appendingPathComponent("manifest.json").path)))
struct DirectFetchTests {
    @Test func verifiedDirectSaveKeepsSourceBytesAndPublishesExclusively() async throws {
        let fixture = try HTTPFixture(); defer { fixture.cleanup() }
        let engine = ConversionEngine(mediaPack: fetchPack)
        let output = fixture.directory.appendingPathComponent("saved.wav")
        let request = try request(fixture, output: output)
        let plan = try await engine.plan(request)
        #expect(plan.inputs.isEmpty)
        #expect(plan.fetchSource?.entityTag == "\"v1\"")
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let roundTrip = try JSONDecoder().decode(TransformationPlan.self, from: JSONEncoder().encode(plan))
        let result = try await engine.run(roundTrip)
        let data = try Data(contentsOf: output)
        #expect(data.count == 32044)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(result.operationID == .fetch)
        #expect(result.fetchReceipt?.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        #expect(result.fetchReceipt?.sourceHost == "127.0.0.1")
        await #expect(throws: FileformError.self) { try await engine.run(plan) }
        #expect(try Data(contentsOf: output) == data)
        let renamed = try await engine.run(engine.plan(self.request(fixture, output: output, collision: .rename)))
        #expect(renamed.artifacts.first?.url.lastPathComponent == "saved-1.wav")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == ["saved-1.wav", "saved.wav"])
    }
    @Test func changedVersionsFalseTypesAndForgedBindingsCannotPublish() async throws {
        let fixture = try HTTPFixture(); defer { fixture.cleanup() }
        let engine = ConversionEngine(mediaPack: fetchPack)
        for path in ["/changed.wav", "/bad.wav"] {
            let plan = try await engine.plan(request(fixture, path: path, output: fixture.directory.appendingPathComponent("rejected.wav")))
            do {
                _ = try await engine.run(plan)
                Issue.record("Changed or invalid source was published")
            } catch let error as FileformError {
                if path == "/changed.wav" { #expect(error.code == .inputChanged) }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        }
        let valid = try await engine.plan(request(fixture, output: fixture.directory.appendingPathComponent("forged.wav")))
        let fake = FetchSourceSnapshot(requestedURL: fixture.url("/media.wav"), resolvedURL: URL(string: "https://unrelated.invalid/media.wav")!,
            contentType: "audio/wav", expectedBytes: 32044, entityTag: "\"v1\"", lastModified: nil)
        let forged = TransformationPlan(request: valid.request, inputs: [], warnings: [], fetchSource: fake)
        await #expect(throws: FileformError.self) { try await engine.run(forged) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        let mismatch = try await engine.plan(request(fixture, output: fixture.directory.appendingPathComponent("wrong.mp4"), format: .mp4))
        await #expect(throws: FileformError.self) { try await engine.run(mismatch) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }
    @Test func fetchInventoryDeclaresNetworkAndDoesNotInventMp3Encoding() async throws {
        let engine = ConversionEngine(mediaPack: fetchPack)
        let inventory = await engine.capabilityInventory()
        #expect(inventory.routes.contains { $0.operationID == .fetch && $0.outputFormat == .mp3 && $0.available && !$0.localProcessing })
        #expect(!inventory.routes.contains { $0.operationID == .conversion && $0.outputFormat == .mp3 && $0.available })
    }
    private func request(_ fixture: HTTPFixture, path: String = "/media.wav", output: URL, format: OutputFormat = .wav,
                         collision: CollisionPolicy = .fail) throws -> TransformationRequest {
        try .init(assets: [], operation: .fetch(url: fixture.url(path), maximumBytes: 100000),
                  output: .init(destination: output, format: format), collisionPolicy: collision)
    }
}

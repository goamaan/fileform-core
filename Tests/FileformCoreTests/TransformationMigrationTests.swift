// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import FileformDomain
import FileformCore

private func migratedRequest(_ input: URL, output: URL) throws -> TransformationRequest {
    try .init(legacy: .init(input: input, destination: output, format: .png))
}

@Test func legacyMigrationProducesEquivalentOutputAndPreservesSource() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let original = try Data(contentsOf: input)
    let engine = ConversionEngine()
    let legacy = ConversionRequest(input: input, destination: fixture.url("legacy.png"), format: .png,
                                   options: .init(maxDimension: 80), collisionPolicy: .rename)
    let migrated = try TransformationRequest(legacy: legacy)
    let restored = try migrated.legacyConversion()
    #expect(restored.input == legacy.input && restored.destination == legacy.destination)
    #expect(restored.options == legacy.options && restored.collisionPolicy == legacy.collisionPolicy)
    let first = try await engine.run(engine.plan(legacy))
    let modern = try TransformationRequest(legacy: .init(input: input, destination: fixture.url("modern.png"),
                                                         format: .png, options: legacy.options))
    let second = try await engine.run(engine.plan(modern))
    #expect(second.status == .succeeded && second.operationID == .conversion)
    let artifact = try #require(second.artifacts.first)
    #expect(second.artifacts.count == 1 && artifact.sourceIDs == ["source"])
    let actualBytes = Int64(try Data(contentsOf: artifact.url).count)
    #expect(artifact.bytes == actualBytes)
    let legacyOutput = try #require(first.output)
    #expect(try Data(contentsOf: legacyOutput) == Data(contentsOf: artifact.url))
    #expect(try Data(contentsOf: input) == original)
}

@Test func serializedTransformationPlansRejectForgedBindingsAndVersions() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let engine = ConversionEngine()
    let destination = fixture.url("never.png")
    let plan = try await engine.plan(migratedRequest(input, output: destination))
    let data = try JSONEncoder().encode(plan)
    let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var unknown = original; unknown["schemaVersion"] = 99
    let unknownPlan = try JSONDecoder().decode(TransformationPlan.self, from: JSONSerialization.data(withJSONObject: unknown))
    await #expect(throws: FileformError.self) { try await engine.run(unknownPlan) }
    var forged = original
    var inputs = try #require(forged["inputs"] as? [[String: Any]])
    inputs[0]["id"] = "forged-source"
    forged["inputs"] = inputs
    let forgedPlan = try JSONDecoder().decode(TransformationPlan.self, from: JSONSerialization.data(withJSONObject: forged))
    await #expect(throws: FileformError.self) { try await engine.run(forgedPlan) }
    var wrongPath = original
    var pathInputs = try #require(wrongPath["inputs"] as? [[String: Any]])
    var inspection = try #require(pathInputs[0]["inspection"] as? [String: Any])
    inspection["input"] = fixture.url("different.png").absoluteString
    pathInputs[0]["inspection"] = inspection; wrongPath["inputs"] = pathInputs
    let wrongPathPlan = try JSONDecoder().decode(TransformationPlan.self, from: JSONSerialization.data(withJSONObject: wrongPath))
    await #expect(throws: FileformError.self) { try await engine.run(wrongPathPlan) }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    try Data("changed input".utf8).write(to: input)
    do { _ = try await engine.run(plan); Issue.record("Changed source unexpectedly executed") }
    catch let error as FileformError { #expect(error.code == .inputChanged) }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func schemaOnlyOperationsAndUnsupportedFidelityPoliciesFailClosed() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let before = try Data(contentsOf: input)
    let asset = AssetReference(id: "source", url: input)
    let interval = MediaInterval(start: .init(ticks: 0, timescale: 1), end: .init(ticks: 1, timescale: 1))
    let operations: [(TransformationOperation, OutputFormat, [AssetReference])] = [
        (.mediaTrim(interval: interval, mode: .exact, audioStream: nil), .mp4, [asset]),
        (.fetch(url: URL(string: "https://example.com/media.mp4")!, maximumBytes: 100), .mp4, [])
    ]
    let destination = fixture.url("never-created")
    let engine = ConversionEngine()
    for (operation, format, assets) in operations {
        let request = try TransformationRequest(assets: assets, operation: operation,
                                               output: .init(destination: destination, format: format, cardinality: operation.cardinality))
        do { _ = try await engine.plan(request); Issue.record("Schema-only operation unexpectedly planned") }
        catch let error as FileformError { #expect(error.code == .unsupported) }
        let untrusted = TransformationPlan(request: request, inputs: [], warnings: [])
        await #expect(throws: FileformError.self) { try await engine.run(untrusted) }
    }
    let policies: [(ConversionParameters, FidelityPolicy)] = [
        (.init(color: .preserve), .allowDeclaredLosses),
        (.init(metadata: .preserve), .allowDeclaredLosses),
        (.init(), .requireLossless)
    ]
    for (parameters, fidelity) in policies {
        let request = try TransformationRequest(assets: [asset], operation: .conversion(parameters),
                                               output: .init(destination: destination, format: .png), fidelity: fidelity)
        do { _ = try await engine.plan(request); Issue.record("Unsupported preservation policy unexpectedly planned") }
        catch let error as FileformError { #expect(error.code == .unsupported) }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try Data(contentsOf: input) == before)
}

@Test func legacyAndModernPlanningRejectHardlinkDestinationEvenWhenRenaming() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let alias = fixture.url("alias.png")
    let before = try Data(contentsOf: input)
    try FileManager.default.linkItem(at: input, to: alias)
    let engine = ConversionEngine()
    let legacy = ConversionRequest(input: input, destination: alias, format: .png, collisionPolicy: .rename)
    await #expect(throws: FileformError.self) { try await engine.plan(legacy) }
    let modern = try TransformationRequest(legacy: legacy)
    await #expect(throws: FileformError.self) { try await engine.plan(modern) }
    #expect(try Data(contentsOf: input) == before)
    #expect(try Data(contentsOf: alias) == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.url("alias-1.png").path))
}

@Test func portableRecipeOmitsPathsAndExecutesAfterRebinding() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let first = try fixture.image(name: "private-original.png", width: 30, height: 20)
    let second = try fixture.image(name: "new-original.png", width: 70, height: 50)
    let firstBefore = try Data(contentsOf: first), secondBefore = try Data(contentsOf: second)
    let privateDestination = fixture.url("private-destination.png")
    let recipe = try TransformationRecipe(name: "PNG copy", request: migratedRequest(first, output: privateDestination))
    let data = try JSONEncoder().encode(recipe)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains(first.path) && !text.contains(first.absoluteString))
    #expect(!text.contains(privateDestination.path) && !text.contains(privateDestination.absoluteString))
    #expect(!text.contains("private-original") && !text.contains("private-destination"))
    let decoded = try JSONDecoder().decode(TransformationRecipe.self, from: data)
    let destination = fixture.url("rebound.png")
    let request = try decoded.bind(assets: [.init(id: "source", url: second)], destination: destination)
    let engine = ConversionEngine()
    let result = try await engine.run(engine.plan(request))
    let artifact = try #require(result.artifacts.first)
    let inspection = try await engine.inspect(artifact.url)
    #expect(inspection.width == 70 && inspection.height == 50)
    #expect(try Data(contentsOf: first) == firstBefore)
    #expect(try Data(contentsOf: second) == secondBefore)
    #expect(!FileManager.default.fileExists(atPath: privateDestination.path))
}

@Test func decodedRecipesRejectUnknownVersionsAndMismatchedBindings() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let recipe = try TransformationRecipe(name: "Copy", request: migratedRequest(input, output: fixture.url("out.png")))
    let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any])
    for (key, value) in [("schemaVersion", 0), ("schemaVersion", 2), ("revision", 0)] {
        var invalid = original; invalid[key] = value
        let data = try JSONSerialization.data(withJSONObject: invalid)
        #expect(throws: FileformError.self) { try JSONDecoder().decode(TransformationRecipe.self, from: data) }
    }
    var duplicateSlots = original; duplicateSlots["assetSlots"] = ["source", "source"]
    let duplicates = try JSONSerialization.data(withJSONObject: duplicateSlots)
    #expect(throws: FileformError.self) { try JSONDecoder().decode(TransformationRecipe.self, from: duplicates) }
    for assets in [[], [AssetReference(id: "wrong", url: input)],
                    [AssetReference(id: "source", url: input), AssetReference(id: "extra", url: input)]] {
        #expect(throws: FileformError.self) { try recipe.bind(assets: assets, destination: fixture.url("never.png")) }
    }
    var unknownOperation = original; unknownOperation["operation"] = ["unknown": [:]]
    let unknown = try JSONSerialization.data(withJSONObject: unknownOperation)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(TransformationRecipe.self, from: unknown) }
}

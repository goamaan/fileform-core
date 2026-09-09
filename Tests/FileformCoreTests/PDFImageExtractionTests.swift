// SPDX-License-Identifier: Apache-2.0
import Foundation
import ImageIO
import Testing
import FileformDomain
@testable import FileformCore

private let extractionRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private func extractionEngine() -> ConversionEngine {
    .init(pdfPack: extractionRoot.appendingPathComponent("Artifacts/PDFPack"), workerExecutable: extractionRoot.appendingPathComponent(".build/debug/fileform-worker"))
}
private func extractionFixtures(_ fixture: Fixture) async throws {
    let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["python3", extractionRoot.appendingPathComponent("Tools/generate-pdf-image-fixtures.py").path, fixture.url("inputs").path], timeout: 60)
    #expect(result.status == 0, "Fixture generator: \(String(decoding: result.stderr, as: UTF8.self))")
}
private func extractionRequest(_ fixture: Fixture, file: String = "supported", pages: [Int] = [0, 1], output: String = "images", collision: CollisionPolicy = .fail) throws -> TransformationRequest {
    try .init(assets: [.init(id: "pdf", url: fixture.url("inputs/\(file).pdf"))], operation: .pdfExtractImages(pages: pages.map { .init(sourceID: "pdf", pageIndex: $0) }), output: .init(destination: fixture.url(output), format: .images, cardinality: .directory), collisionPolicy: collision)
}

@Test func pdfImageExtractionPreservesBytesRGBAObjectReuseAndInheritedNestedResources() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }; try await extractionFixtures(fixture)
    let engine = extractionEngine(), request = try extractionRequest(fixture, pages: [0, 1, 0])
    let original = try Data(contentsOf: request.assets[0].url)
    let plan = try await engine.plan(request), details = try #require(plan.pdfImageExtraction)
    #expect(details.discoveredCount == 2 && details.supportedCount == 2 && details.skippedCount == 0)
    let jpegCandidate = try #require(details.candidates.first { $0.objectNumber == 5 })
    #expect(jpegCandidate.resourcePages.map(\.pageIndex) == [0, 1])
    let rgbaCandidate = try #require(details.candidates.first { $0.objectNumber == 7 })
    #expect(rgbaCandidate.resourcePaths == ["page 1: /Form → /RGBA"])
    let result = try await engine.run(plan)
    #expect(result.artifacts.count == 2 && result.pdfImageExtraction?.supportedCount == 2)
    let jpeg = try #require(result.artifacts.first { $0.format == .jpeg }), png = try #require(result.artifacts.first { $0.format == .png })
    #expect(try Data(contentsOf: jpeg.url) == Data(contentsOf: fixture.url("inputs/original.jpg")))
    let source = try #require(CGImageSourceCreateWithURL(png.url as CFURL, nil)), decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decoded.width == 2 && decoded.height == 2 && decoded.alphaInfo == .last)
    #expect(try decoded.dataProvider?.data as Data? == Data(contentsOf: fixture.url("inputs/expected-rgba.bin")))
    #expect(try png.pdfEmbeddedImage?.sha256 == PDFPack.hash(png.url))
    #expect(try Data(contentsOf: request.assets[0].url) == original)
    let recipe = try TransformationRecipe(name: "Embedded originals", request: request)
    let rebound = try JSONDecoder().decode(TransformationRecipe.self, from: JSONEncoder().encode(recipe)).bind(assets: request.assets, destination: fixture.url("recipe"))
    #expect(rebound.operation == request.operation && rebound.output.format == .images)
    let persisted = try JSONDecoder().decode(TransformationResult.self, from: JSONEncoder().encode(result))
    #expect(persisted.artifacts[0].pdfEmbeddedImage == result.artifacts[0].pdfEmbeddedImage)
    let selected = try await engine.plan(extractionRequest(fixture, pages: [1], output: "selected"))
    #expect(selected.pdfImageExtraction?.discoveredCount == 1)
    #expect(selected.pdfImageExtraction?.candidates.first?.resourcePages.map(\.pageIndex) == [1])
}

@Test func pdfImageExtractionReportsSkipsZeroImagesAndPrimaryMaskReuse() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }; try await extractionFixtures(fixture)
    let engine = extractionEngine()
    let mixed = try await engine.plan(extractionRequest(fixture, file: "mixed"))
    #expect(mixed.pdfImageExtraction?.discoveredCount == 3 && mixed.pdfImageExtraction?.skippedCount == 1)
    #expect(mixed.pdfImageExtraction?.candidates.first { $0.objectNumber == 13 }?.skipReason?.contains("color space") == true)
    let partial = try await engine.run(mixed)
    #expect(partial.artifacts.count == 2 && partial.pdfImageExtraction?.skippedCount == 1)
    for name in ["no-images", "predictor", "stencil", "jpx", "decode", "matte"] {
        let plan = try await engine.plan(extractionRequest(fixture, file: name, output: name))
        #expect(plan.pdfImageExtraction?.supportedCount == 0)
        if name != "no-images" { #expect(plan.pdfImageExtraction?.skippedCount == 1) }
        do { _ = try await engine.run(plan); Issue.record("Unsupported extraction unexpectedly succeeded.") }
        catch let error as FileformError { #expect(error.code == .unsupported) }
        #expect(!FileManager.default.fileExists(atPath: fixture.url(name).path))
    }
    let primary = try await engine.plan(extractionRequest(fixture, file: "primary-mask", output: "primary"))
    #expect(primary.pdfImageExtraction?.discoveredCount == 3)
    #expect(primary.pdfImageExtraction?.candidates.first { $0.objectNumber == 8 }?.resourcePaths == ["page 1: /MaskAsPrimary"])
    let primaryResult = try await engine.run(primary)
    #expect(primaryResult.artifacts.count == 3)
}

@Test func pdfImageExtractionGeneralizedStreamsAreExactAndMalformedSamplesFailAtomically() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }; try await extractionFixtures(fixture)
    let engine = extractionEngine()
    var expected: Data?
    for name in ["plain", "hex", "ascii85", "runlength", "filter-chain", "gray"] {
        let result = try await engine.run(engine.plan(extractionRequest(fixture, file: name, output: name)))
        let artifact = try #require(result.artifacts.first), source = try #require(CGImageSourceCreateWithURL(artifact.url as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), samples = try #require(decoded.dataProvider?.data) as Data
        if name == "plain" { expected = samples }
        else if name != "gray" { #expect(samples == expected) }
        else { #expect(samples == Data([255,255,255,255,128,128,128,255,0,0,0,255,255,255,255,255])) }
    }
    for name in ["short", "long"] {
        let plan = try await engine.plan(extractionRequest(fixture, file: name, output: name))
        do { _ = try await engine.run(plan); Issue.record("Malformed samples unexpectedly succeeded.") }
        catch let error as FileformError { #expect([.verificationFailed, .resourceLimit].contains(error.code)) }
        #expect(!FileManager.default.fileExists(atPath: fixture.url(name).path))
    }
}

@Test func pdfImageExtractionRejectsAliasesChangesCancellationAndClobber() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }; try await extractionFixtures(fixture)
    let engine = extractionEngine(), request = try extractionRequest(fixture)
    let plan = try await engine.plan(request)
    let result = try await engine.run(plan)
    let bytes = try result.artifacts.map { try Data(contentsOf: $0.url) }
    do { _ = try await engine.run(plan); Issue.record("Existing folder overwritten.") }
    catch let error as FileformError { #expect(error.code == .destinationExists) }
    #expect(try result.artifacts.map { try Data(contentsOf: $0.url) } == bytes)
    let renamed = try await engine.run(engine.plan(extractionRequest(fixture, collision: .rename)))
    #expect(renamed.artifacts.first?.url.deletingLastPathComponent().lastPathComponent == "images-1")
    let alias = fixture.url("alias.pdf")
    try FileManager.default.linkItem(at: request.assets[0].url, to: alias)
    let duplicate = try TransformationRequest(assets: request.assets + [.init(id: "alias", url: alias)], operation: request.operation, output: .init(destination: fixture.url("duplicate"), format: .images, cardinality: .directory))
    do { _ = try await engine.plan(duplicate); Issue.record("Duplicate physical source accepted.") }
    catch let error as FileformError { #expect(error.code == .invalidRequest) }
    let aliasOutput = try TransformationRequest(assets: request.assets, operation: request.operation, output: .init(destination: alias, format: .images, cardinality: .directory))
    do { _ = try await engine.plan(aliasOutput); Issue.record("Source alias destination accepted.") }
    catch let error as FileformError { #expect(error.code == .invalidRequest) }
    let cancelledPlan = try await engine.plan(extractionRequest(fixture, output: "cancelled"))
    let task = Task { try await engine.run(cancelledPlan) { event in if event.phase == .encoding { withUnsafeCurrentTask { $0?.cancel() } } } }
    do { _ = try await task.value; Issue.record("Cancelled extraction published.") } catch is CancellationError {} catch let error as FileformError { #expect(error.code == .cancelled) }
    #expect(!FileManager.default.fileExists(atPath: fixture.url("cancelled").path))
    let changed = try await engine.plan(extractionRequest(fixture, output: "changed"))
    let handle = try FileHandle(forWritingTo: request.assets[0].url); try handle.seekToEnd(); try handle.write(contentsOf: Data("\n% modified".utf8)); try handle.close()
    do { _ = try await engine.run(changed); Issue.record("Changed source accepted.") }
    catch let error as FileformError { #expect(error.code == .inputChanged) }
    #expect(!FileManager.default.fileExists(atPath: fixture.url("changed").path))
}

@Test func pdfImageExtractionGraphUsesGenerationAndRejectsCyclicIndirectDefinitions() throws {
    let root: [String: Any] = ["pages": [["object": "1 0 R"]], "encrypt": ["encrypted": false], "qpdf": [["jsonversion": 2], [
        "obj:1 0 R": ["value": ["/Resources": ["/XObject": ["/Image": "2 7 R"]]]],
        "obj:2 7 R": ["stream": ["dict": ["/Subtype": "/Image", "/Width": 1, "/Height": 1, "/BitsPerComponent": 8, "/ColorSpace": "/DeviceRGB"]]]]]]
    let graph = try PDFImageGraph(data: JSONSerialization.data(withJSONObject: root))
    let image = try #require(graph.images(sourceID: "a", pages: [.init(sourceID: "a", pageIndex: 0)]).first)
    #expect(image.candidate.objectNumber == 2 && image.candidate.generation == 7 && image.reference == "2 7 R")
    let cyclic: [String: Any] = ["pages": [["object": "1 0 R"]], "encrypt": ["encrypted": false], "qpdf": [["jsonversion": 2], ["obj:1 0 R": ["value": "1 0 R"]]]]
    let malformed = try PDFImageGraph(data: JSONSerialization.data(withJSONObject: cyclic))
    #expect(throws: FileformError.self) { try malformed.images(sourceID: "a", pages: [.init(sourceID: "a", pageIndex: 0)]) }
}

@Test func pdfImageExtractionProcessStdoutIsBoundedAndExclusive() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let output = fixture.url("stdout")
    do { _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["123456789"], stdoutFile: output, maximumStdoutBytes: 4); Issue.record("Oversized completed output accepted.") }
    catch let error as FileformError { #expect(error.code == .resourceLimit) }
    let original = try Data(contentsOf: output)
    do { _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["replace"], stdoutFile: output); Issue.record("Existing output truncated.") }
    catch let error as FileformError { #expect(error.code == .ioFailure) }
    #expect(try Data(contentsOf: output) == original)
}

@Test func pdfImageExtractionRejectsUnboundedProvenanceAndInvalidCollectionContracts() throws {
    let aliases = Dictionary(uniqueKeysWithValues: (0..<17000).map { ("/" + String(repeating: "a", count: 247) + String(format: "%05d", $0), "2 0 R") })
    let root: [String: Any] = ["pages": [["object": "1 0 R"]], "encrypt": ["encrypted": false], "qpdf": [["jsonversion": 2], [
        "obj:1 0 R": ["value": ["/Resources": ["/XObject": aliases]]],
        "obj:2 0 R": ["stream": ["dict": ["/Subtype": "/Image", "/Width": 1, "/Height": 1, "/BitsPerComponent": 8, "/ColorSpace": "/DeviceRGB"]]]]]]
    let graph = try PDFImageGraph(data: JSONSerialization.data(withJSONObject: root))
    do { _ = try graph.images(sourceID: "a", pages: [.init(sourceID: "a", pageIndex: 0)]); Issue.record("Unbounded provenance accepted.") }
    catch let error as FileformError { #expect(error.code == .resourceLimit) }
    let asset = AssetReference(id: "a", url: URL(fileURLWithPath: "/source.pdf")), output = URL(fileURLWithPath: "/images")
    #expect(throws: FileformError.self) { try TransformationRequest(assets: [asset], operation: .conversion(.init()), output: .init(destination: output, format: .images)) }
    #expect(throws: FileformError.self) { try TransformationRequest(assets: [asset], operation: .pdfExtractImages(pages: [.init(sourceID: "a", pageIndex: 0, clockwiseRotation: 90)]), output: .init(destination: output, format: .images, cardinality: .directory)) }
    #expect(throws: FileformError.self) { try TransformationRequest(assets: [asset], operation: .pdfExtractImages(pages: [.init(sourceID: "a", pageIndex: 0)]), output: .init(destination: output, format: .png, cardinality: .directory)) }
}

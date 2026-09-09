// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import PDFKit
import CoreGraphics
import Testing
import FileformDomain
@testable import FileformCore

private func pdfAssemblyPlan(_ inputs: [URL], operation: TransformationOperation, destination: URL,
                             collision: CollisionPolicy = .fail, fidelity: FidelityPolicy = .allowDeclaredLosses) throws -> TransformationPlan {
    let assets = inputs.enumerated().map { AssetReference(id: "s\($0.offset)", url: $0.element) }
    let inspections = try assets.map { asset in
        let identity = try FileSafety.identity(asset.url)
        let inspection = DocumentBackend.recognizesPDF(asset.url)
            ? try DocumentBackend.inspect(asset.url, identity: identity)
            : try ImageBackend.inspect(asset.url, identity: identity)
        return InspectedAsset(id: asset.id, inspection: inspection)
    }
    let request = try TransformationRequest(assets: assets, operation: operation,
        output: .init(destination: destination, format: .pdf, cardinality: operation.cardinality),
        fidelity: fidelity, collisionPolicy: collision)
    return try PDFCompositionBackend.plan(request: request, inspections: inspections)
}

@Test func pdfCompositionPreservesOrderedDuplicatesTextBoxesAndRotations() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.pdf()
    let source = try #require(PDFDocument(url: input))
    let page = try #require(source.page(at: 1))
    page.rotation = 90
    page.setBounds(CGRect(x: 20, y: 30, width: 550, height: 740), for: .cropBox)
    #expect(source.write(to: input))
    let original = try Data(contentsOf: input)
    let pages = [PageReference(sourceID: "s0", pageIndex: 1, clockwiseRotation: 90),
                 PageReference(sourceID: "s0", pageIndex: 0),
                 PageReference(sourceID: "s0", pageIndex: 1, clockwiseRotation: 270)]
    let plan = try pdfAssemblyPlan([input], operation: .pdfComposition(pages: pages), destination: fixture.url("combined.pdf"))
    let result = try PDFCompositionBackend.execute(plan: plan, progress: { _ in })
    #expect(result.status == .succeeded && result.artifacts.count == 1)
    #expect(result.artifacts[0].sourceIDs == ["s0"])
    let output = try #require(PDFDocument(url: result.artifacts[0].url))
    #expect(output.pageCount == 3)
    #expect(output.page(at: 0)?.string?.contains("Second page") == true)
    #expect(output.page(at: 1)?.string?.contains("First page") == true)
    #expect(output.page(at: 2)?.string?.contains("Second page") == true)
    #expect(output.page(at: 0)?.rotation == 180)
    #expect(output.page(at: 2)?.rotation == 0)
    #expect(output.page(at: 0)?.bounds(for: .cropBox) == page.bounds(for: .cropBox))
    #expect(try Data(contentsOf: input) == original)
}

@Test func pdfCompositionCombinesOrientedImageAndPDFAtExplicitPageSizes() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let pdf = try fixture.pdf()
    let image = try fixture.image(alpha: true, orientation: 6, width: 120, height: 80)
    let plan = try pdfAssemblyPlan([pdf, image], operation: .pdfComposition(pages: [
        .init(sourceID: "s1", pageIndex: 0), .init(sourceID: "s0", pageIndex: 0), .init(sourceID: "s1", pageIndex: 0, clockwiseRotation: 90)
    ]), destination: fixture.url("mixed.pdf"))
    #expect(plan.warnings.contains(where: { $0.contains("one PDF point") && $0.contains("sRGB") }))
    let result = try PDFCompositionBackend.execute(plan: plan, progress: { _ in })
    let output = try #require(PDFDocument(url: result.artifacts[0].url))
    #expect(output.pageCount == 3)
    #expect(output.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 80, height: 120))
    #expect(output.page(at: 1)?.string?.contains("First page") == true)
    #expect(output.page(at: 2)?.rotation == 90)
    #expect(result.artifacts[0].sourceIDs == ["s1", "s0"])
}

@Test func pdfSplitPublishesOneCompleteDirectoryAndRetainsExistingFolder() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.pdf()
    let destination = fixture.url("parts")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    try Data("retain".utf8).write(to: destination.appendingPathComponent("existing.txt"))
    let plan = try pdfAssemblyPlan([input], operation: .pdfSplit(groups: [
        [.init(sourceID: "s0", pageIndex: 1)],
        [.init(sourceID: "s0", pageIndex: 0), .init(sourceID: "s0", pageIndex: 0)]
    ]), destination: destination, collision: .rename)
    let result = try PDFCompositionBackend.execute(plan: plan, progress: { _ in })
    #expect(result.artifacts.count == 2)
    #expect(Set(result.artifacts.map { $0.url.deletingLastPathComponent() }) == [fixture.url("parts-1")])
    let first = try #require(PDFDocument(url: result.artifacts[0].url))
    let second = try #require(PDFDocument(url: result.artifacts[1].url))
    #expect(first.pageCount == 1 && first.string?.contains("Second page") == true)
    #expect(second.pageCount == 2 && second.string?.contains("Second page") == false)
    #expect(try String(contentsOf: destination.appendingPathComponent("existing.txt"), encoding: .utf8) == "retain")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".fileform-pdf-") })
}

@Test func pdfAssemblyRejectsInvalidPagesStrictFidelityAndSourceAliases() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.pdf()
    let valid = TransformationOperation.pdfComposition(pages: [.init(sourceID: "s0", pageIndex: 0)])
    #expect(throws: FileformError.self) { try pdfAssemblyPlan([input], operation: .pdfComposition(pages: [.init(sourceID: "s0", pageIndex: 2)]), destination: fixture.url("bad.pdf")) }
    #expect(throws: FileformError.self) { try pdfAssemblyPlan([input], operation: valid, destination: fixture.url("strict.pdf"), fidelity: .requireLossless) }
    let alias = fixture.url("alias.pdf")
    #expect(link(input.path, alias.path) == 0)
    #expect(throws: FileformError.self) { try pdfAssemblyPlan([input], operation: valid, destination: alias, collision: .rename) }
    // Aliases of a source unused by the composition remain forbidden.
    let second = try fixture.image()
    let secondAlias = fixture.url("second-alias.pdf")
    #expect(link(second.path, secondAlias.path) == 0)
    #expect(throws: FileformError.self) { try pdfAssemblyPlan([input, second], operation: valid, destination: secondAlias) }
}

@Test func pdfAssemblyRejectsEncryptedSources() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.pdf()
    let document = try #require(PDFDocument(url: input))
    let locked = fixture.url("locked.pdf")
    #expect(document.write(to: locked, withOptions: [.userPasswordOption: "synthetic", .ownerPasswordOption: "synthetic-owner"]))
    #expect(throws: FileformError.self) {
        try pdfAssemblyPlan([locked], operation: .pdfComposition(pages: [.init(sourceID: "s0", pageIndex: 0)]), destination: fixture.url("output.pdf"))
    }
}

@Test func pdfSplitCancellationAtPublicationRemovesEveryStagedPart() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.pdf(); let original = try Data(contentsOf: input)
    let destination = fixture.url("parts")
    let plan = try pdfAssemblyPlan([input], operation: .pdfSplit(groups: [
        [.init(sourceID: "s0", pageIndex: 0)], [.init(sourceID: "s0", pageIndex: 1)]
    ]), destination: destination)
    let task = Task.detached {
        try PDFCompositionBackend.execute(plan: plan) { event in
            if event.phase == .saving { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    do { _ = try await task.value; Issue.record("Cancelled split published") }
    catch is CancellationError { }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try Data(contentsOf: input) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".fileform-pdf-") })
}

@Test func pdfAssemblyRechecksEverySourceAtCommitAndRenameCandidate() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.pdf()
    let destination = fixture.url("out.pdf")
    try Data("old output".utf8).write(to: destination)
    let alternate = fixture.url("out-1.pdf")
    let plan = try pdfAssemblyPlan([input], operation: .pdfComposition(pages: [.init(sourceID: "s0", pageIndex: 0)]), destination: destination, collision: .rename)
    #expect(link(input.path, alternate.path) == 0)
    #expect(throws: FileformError.self) { try PDFCompositionBackend.execute(plan: plan, progress: { _ in }) }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "old output")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".fileform-pdf-") })
}

@Test func pdfAssemblyChangedSourceCannotPublishVerifiedCandidate() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.pdf()
    let destination = fixture.url("out.pdf")
    let plan = try pdfAssemblyPlan([input], operation: .pdfComposition(pages: [.init(sourceID: "s0", pageIndex: 0)]), destination: destination)
    #expect(throws: FileformError.self) {
        try PDFCompositionBackend.execute(plan: plan) { event in
            if event.phase == .saving { try? Data("changed synthetic source".utf8).write(to: input) }
        }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".fileform-pdf-") })
}

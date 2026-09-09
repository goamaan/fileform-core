// SPDX-License-Identifier: Apache-2.0
import Foundation
import PDFKit
import Testing
import FileformDomain
@testable import FileformCore

private let pdfCoreRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private func optimizer(_ pack: URL? = nil) -> ConversionEngine {
    ConversionEngine(pdfPack: pack ?? pdfCoreRoot.appendingPathComponent("Artifacts/PDFPack"), workerExecutable: pdfCoreRoot.appendingPathComponent(".build/debug/fileform-worker"))
}
private func structuralPDF(_ fixture: Fixture, interactive: Bool = false) throws -> URL {
    var objects = ["<< /Type /Catalog /Pages 2 0 R /Metadata 10 0 R \(interactive ? "/AcroForm << /Fields [] >>" : "") >>", "<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 >>", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    for index in 0..<3 {
        let contentID = 5 + index * 2
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [10 20 430 560] /CropBox [15 25 425 555] /TrimBox [20 30 420 550] /BleedBox [18 28 422 552] /ArtBox [25 35 415 545] /Rotate \(index * 90) /Resources << /Font << /F1 3 0 R >> >> /Contents \(contentID) 0 R >>")
        let content = "BT /F1 12 Tf 30 500 Td (Distinct page \(index)) Tj ET\n" + (0..<200).map { "q 0.2 0.4 0.6 RG \(30 + $0 % 20) \(40 + $0) m 200 \(40 + $0) l S Q\n" }.joined()
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")
    }
    let xmp = "<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description rdf:about='' /></rdf:RDF></x:xmpmeta>"
    objects.append("<< /Type /Metadata /Subtype /XML /Length \(xmp.utf8.count) >>\nstream\n\(xmp)\nendstream")
    objects.append("<< /Title (Preserved fixture title) /Author (Fileform fixture owner) /CustomNumber 42 >>")
    var data = Data("%PDF-1.4\n".utf8); var offsets = [0]
    for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
    let xref = data.count
    data.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
    for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
    data.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R /Info 11 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
    let url = fixture.url("structural.pdf"); try data.write(to: url); return url
}
@Test func pdfOptimizationPreservesAllPagesAndExactFitBoundary() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try structuralPDF(fixture); let original = try Data(contentsOf: input); let engine = optimizer()
    let request = ConversionRequest(input: input, destination: fixture.url("optimized.pdf"), format: .pdf, goal: .compress)
    let typed = try TransformationRequest(legacy: request)
    #expect(typed.fidelity == .requireLossless)
    let plan = try await engine.plan(typed)
    let result = try await engine.run(plan)
    #expect(result.status == .succeeded)
    let artifact = try #require(result.artifacts.first)
    #expect(artifact.bytes < Int64(original.count))
    let source = try #require(PDFDocument(url: input)), output = try #require(PDFDocument(url: artifact.url))
    #expect(source.pageCount == 3 && output.pageCount == 3)
    for i in 0..<3 {
        let a = try #require(source.page(at: i)), b = try #require(output.page(at: i))
        #expect(a.string == b.string); #expect(a.rotation == b.rotation)
        for box: PDFDisplayBox in [.mediaBox, .cropBox, .trimBox, .bleedBox, .artBox] { #expect(a.bounds(for: box) == b.bounds(for: box)) }
    }
    let fit = try await engine.plan(ConversionRequest(input: input, destination: fixture.url("fit.pdf"), format: .pdf, goal: .fit, options: .init(maximumBytes: artifact.bytes)))
    #expect(try await engine.run(fit).status == .succeeded)
    let unmet = try await engine.plan(ConversionRequest(input: input, destination: fixture.url("unmet.pdf"), format: .pdf, goal: .fit, options: .init(maximumBytes: artifact.bytes - 1)))
    do { _ = try await engine.run(unmet); Issue.record("Expected targetUnmet") } catch let error as FileformError { #expect(error.code == .targetUnmet) }
    #expect(!FileManager.default.fileExists(atPath: fixture.url("unmet.pdf").path))
    let again = try await engine.plan(ConversionRequest(input: artifact.url, destination: fixture.url("again.pdf"), format: .pdf, goal: .compress))
    #expect(try await engine.run(again).status == .notSmaller)
    #expect(!FileManager.default.fileExists(atPath: fixture.url("again.pdf").path))
    #expect(try Data(contentsOf: input) == original)
}
@Test func pdfOptimizationRejectsUnsupportedPoliciesAndInteractiveDocuments() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try structuralPDF(fixture, interactive: true); let engine = optimizer()
    await #expect(throws: FileformError.self) { try await engine.plan(ConversionRequest(input: input, destination: fixture.url("out.pdf"), format: .pdf, goal: .compress)) }
    let invalid = try TransformationRequest(assets: [.init(id: "source", url: input)], operation: .conversion(.init(goal: .compress)), output: .init(destination: fixture.url("out.pdf"), format: .pdf))
    await #expect(throws: FileformError.self) { try await engine.plan(invalid) }
}
@Test func pdfOptimizationPackIntegrityAndSafePublication() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try structuralPDF(fixture), destination = fixture.url("out.pdf")
    let engine = optimizer(); let request = ConversionRequest(input: input, destination: destination, format: .pdf, goal: .compress)
    let plan = try await engine.plan(request)
    try Data("existing".utf8).write(to: destination)
    await #expect(throws: FileformError.self) { try await engine.run(plan) }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "existing")
    let alias = ConversionRequest(input: input, destination: input, format: .pdf, goal: .compress)
    await #expect(throws: FileformError.self) { try await engine.plan(alias) }
    let missing = optimizer(fixture.url("missing"))
    await #expect(throws: FileformError.self) { try await missing.plan(request) }
    let pack = fixture.url("pack"); try FileManager.default.copyItem(at: pdfCoreRoot.appendingPathComponent("Artifacts/PDFPack"), to: pack)
    let binary = pack.appendingPathComponent("bin/qpdf"); let file = try FileHandle(forWritingTo: binary); try file.seekToEnd(); try file.write(contentsOf: Data([0])); try file.close()
    #expect(throws: FileformError.self) { try PDFPack(directory: pack) }
    let before = try await engine.plan(ConversionRequest(input: input, destination: fixture.url("changed.pdf"), format: .pdf, goal: .compress))
    try Data("changed".utf8).write(to: input)
    await #expect(throws: FileformError.self) { try await engine.run(before) }
}

@Test func pdfOptimizationCancellationLeavesNoOutput() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try structuralPDF(fixture), destination = fixture.url("cancelled.pdf")
    let engine = optimizer()
    let plan = try await engine.plan(ConversionRequest(input: input, destination: destination, format: .pdf, goal: .compress))
    let (events, continuation) = AsyncStream<ProgressEvent>.makeStream()
    let task = Task {
        defer { continuation.finish() }
        return try await engine.run(plan) { continuation.yield($0) }
    }
    for await event in events {
        if event.phase == .encoding { task.cancel(); break }
    }
    do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(FileManager.default.fileExists(atPath: input.path))
}

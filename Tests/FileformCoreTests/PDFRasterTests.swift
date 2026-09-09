// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import PDFKit
import CoreGraphics
import ImageIO
import Testing
import FileformDomain
@testable import FileformCore

private let rasterRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private func rasterEngine() -> ConversionEngine { .init(workerExecutable: rasterRoot.appendingPathComponent(".build/debug/fileform-worker")) }
private func rasterRequest(_ inputs: [URL], pages: [PageReference], destination: URL, dpi: Int = 72, format: OutputFormat = .png, quality: Double = 0.9, collision: CollisionPolicy = .fail, fidelity: FidelityPolicy = .allowDeclaredLosses) throws -> TransformationRequest {
    try .init(assets: inputs.enumerated().map { .init(id: "s\($0.offset)", url: $0.element) }, operation: .pdfRasterize(pages: pages, dpi: dpi, quality: quality), output: .init(destination: destination, format: format, cardinality: .directory), fidelity: fidelity, collisionPolicy: collision)
}
private func rasterImage(_ url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}
private func rasterColor(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return (0..<3).map { data[(y * image.width + x) * 4 + $0] }
}
private func coloredPDF(_ fixture: Fixture) throws -> URL {
    let url = fixture.url("colors.pdf")
    var box = CGRect(x: 0, y: 0, width: 200, height: 140)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    for second in [false, true] {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: second ? 0 : 1, green: second ? 1 : 0, blue: 0, alpha: 1))
        context.fill(box)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 20, y: 30, width: 40, height: 60))
        context.endPDFPage()
    }
    context.closePDF()
    let document = try #require(PDFDocument(url: url))
    for index in 0..<2 {
        let page = try #require(document.page(at: index))
        page.setBounds(CGRect(x: 20, y: 30, width: 100, height: 60), for: .cropBox)
    }
    document.page(at: 1)?.rotation = 90
    let modified = fixture.url("cropped.pdf")
    #expect(document.write(to: modified))
    return modified
}

@Test func pdfRasterExportsOrderedDuplicatesCropBoxesRotationDPIAndProvenance() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try coloredPDF(fixture), original = try Data(contentsOf: input)
    let pages: [PageReference] = [.init(sourceID: "s0", pageIndex: 1), .init(sourceID: "s0", pageIndex: 0), .init(sourceID: "s0", pageIndex: 1), .init(sourceID: "s0", pageIndex: 0, clockwiseRotation: 90)]
    let request = try rasterRequest([input], pages: pages, destination: fixture.url("pages"), dpi: 144)
    let engine = rasterEngine(), plan = try await engine.plan(request)
    let result = try await engine.run(plan)
    #expect(result.operationID == .pdfRasterize && result.artifacts.count == 4)
    #expect(result.artifacts.map { $0.url.lastPathComponent } == ["001.png", "002.png", "003.png", "004.png"])
    #expect(result.artifacts.compactMap { $0.sourcePages?.first } == pages)
    let images = try result.artifacts.map { try rasterImage($0.url) }
    #expect(images.map(\.width) == [120, 200, 120, 120])
    #expect(images.map(\.height) == [200, 120, 200, 200])
    // Crop origin is respected: the left region is blue and right region red.
    let blue = try rasterColor(images[1], x: 10, y: 60), red = try rasterColor(images[1], x: 180, y: 60)
    #expect(blue[2] > 240 && blue[0] < 60 && blue[1] < 60)
    #expect(red[0] > 240 && red[1] < 60 && red[2] < 60)
    // Both native and requested clockwise rotations move blue to the same edge.
    let nativeTop = try rasterColor(images[0], x: 60, y: 10), extraTop = try rasterColor(images[3], x: 60, y: 10)
    let nativeBottom = try rasterColor(images[0], x: 60, y: 190), extraBottom = try rasterColor(images[3], x: 60, y: 190)
    #expect(nativeTop == extraTop && nativeTop[2] > 240)
    #expect(nativeBottom[1] > 240 && extraBottom[0] > 240)
    #expect(try Data(contentsOf: result.artifacts[0].url) == Data(contentsOf: result.artifacts[2].url))
    #expect(try Data(contentsOf: input) == original)
}

@Test func pdfRasterSupportsMixedOrientedImagePagesAndJPEG() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let pdf = try coloredPDF(fixture)
    let image = try fixture.image(alpha: true, orientation: 6, width: 120, height: 80)
    let request = try rasterRequest([pdf, image], pages: [.init(sourceID: "s1", pageIndex: 0, clockwiseRotation: 90), .init(sourceID: "s0", pageIndex: 0)], destination: fixture.url("mixed"), dpi: 144, format: .jpeg, quality: 0.6)
    let engine = rasterEngine(), plan = try await engine.plan(request)
    let result = try await engine.run(plan)
    let images = try result.artifacts.map { try rasterImage($0.url) }
    #expect(images.map(\.width) == [240, 200] && images.map(\.height) == [160, 120])
    #expect(result.artifacts.map(\.sourceIDs) == [["s1"], ["s0"]])
    for artifact in result.artifacts { #expect(try Data(contentsOf: artifact.url).suffix(2) == Data([0xff, 0xd9])) }
}

@Test func pdfRasterSchemaRecipeAndPolicyValidation() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.pdf(), page = PageReference(sourceID: "s0", pageIndex: 0)
    let valid = try rasterRequest([input], pages: [page, page], destination: fixture.url("pages"))
    let decoded = try JSONDecoder().decode(TransformationRequest.self, from: JSONEncoder().encode(valid))
    #expect(decoded.operation == valid.operation)
    let recipe = try TransformationRecipe(name: "Page images", request: valid)
    let rebound = try recipe.bind(assets: valid.assets, destination: fixture.url("rebound"))
    #expect(rebound.output.cardinality == .directory && rebound.operation == valid.operation)
    for dpi in [0, 35, 601, Int.max] { #expect(throws: FileformError.self) { try rasterRequest([input], pages: [page], destination: fixture.url("bad"), dpi: dpi) } }
    for quality in [0.0, 1.01, Double.nan, Double.infinity] { #expect(throws: FileformError.self) { try rasterRequest([input], pages: [page], destination: fixture.url("bad"), quality: quality) } }
    #expect(throws: FileformError.self) { try rasterRequest([input], pages: [], destination: fixture.url("bad")) }
    #expect(throws: FileformError.self) { try rasterRequest([input], pages: [page], destination: fixture.url("bad"), format: .pdf) }
    let engine = rasterEngine()
    for request in [try rasterRequest([input], pages: [page], destination: fixture.url("strict"), fidelity: .requireLossless),
                    try rasterRequest([input], pages: [.init(sourceID: "s0", pageIndex: 99)], destination: fixture.url("missing"))] {
        await #expect(throws: FileformError.self) { try await engine.plan(request) }
    }
    let inventory = await engine.capabilityInventory()
    #expect(inventory.routes.filter { $0.operationID == .pdfRasterize }.count == 2)
}

@Test func pdfRasterRejectsOversizedGeometryWithoutSilentDownscale() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.pdf(), document = try #require(PDFDocument(url: input))
    let page = try #require(document.page(at: 0))
    page.setBounds(CGRect(x: 0, y: 0, width: 10000, height: 10000), for: .mediaBox)
    page.setBounds(CGRect(x: 0, y: 0, width: 10000, height: 10000), for: .cropBox)
    #expect(document.write(to: input))
    let request = try rasterRequest([input], pages: [.init(sourceID: "s0", pageIndex: 0)], destination: fixture.url("big"))
    do { _ = try await rasterEngine().plan(request); Issue.record("Oversized raster accepted") }
    catch let error as FileformError { #expect(error.code == .resourceLimit) }
    #expect(!FileManager.default.fileExists(atPath: fixture.url("big").path))
}

@Test func pdfRasterAtomicCollisionAliasesChangedSourcesAndCancellation() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try coloredPDF(fixture), extra = try fixture.image()
    let destination = fixture.url("pages"), engine = rasterEngine()
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let sentinel = destination.appendingPathComponent("keep")
    try Data("keep".utf8).write(to: sentinel)
    let request = try rasterRequest([input, extra], pages: [.init(sourceID: "s0", pageIndex: 0)], destination: destination, collision: .rename)
    let plan = try await engine.plan(request)
    // Even an unused source must not be overwritten via a rename candidate.
    #expect(link(extra.path, fixture.url("pages-1").path) == 0)
    await #expect(throws: FileformError.self) { try await engine.run(plan) }
    try FileManager.default.removeItem(at: fixture.url("pages-1"))
    let result = try await engine.run(plan)
    #expect(result.artifacts[0].url.deletingLastPathComponent() == fixture.url("pages-1"))
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
    let cancelledURL = fixture.url("cancelled")
    let cancelledPlan = try await engine.plan(rasterRequest([input], pages: [.init(sourceID: "s0", pageIndex: 0), .init(sourceID: "s0", pageIndex: 1)], destination: cancelledURL))
    let task = Task { try await engine.run(cancelledPlan) { event in if event.phase == .saving { withUnsafeCurrentTask { $0?.cancel() } } } }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: cancelledURL.path))
    let changedURL = fixture.url("changed")
    let changedPlan = try await engine.plan(rasterRequest([input, extra], pages: [.init(sourceID: "s0", pageIndex: 0)], destination: changedURL))
    await #expect(throws: FileformError.self) { try await engine.run(changedPlan) { event in if event.phase == .saving { try? Data("changed".utf8).write(to: extra) } } }
    #expect(!FileManager.default.fileExists(atPath: changedURL.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".fileform-") })
}

@Test func pdfRasterWorkerProtocolRejectsInvalidBoundsAndScratchHandles() throws {
    let asset = WorkerAssetHandle(assetID: "s", descriptor: 3)
    let operation = WorkerOperation.pageRaster(asset: asset, outputDescriptor: 4, pageIndex: 0, clockwiseRotation: 90, dpi: 300, format: .jpeg, quality: 0.8)
    let request = try WorkerRequest(operation: operation)
    #expect(try JSONDecoder().decode(WorkerRequest.self, from: JSONEncoder().encode(request)) == request)
    for invalid in [WorkerOperation.pageRaster(asset: asset, outputDescriptor: 3, pageIndex: 0, clockwiseRotation: 0, dpi: 72, format: .png, quality: 1),
                    .pageRaster(asset: asset, outputDescriptor: 4, pageIndex: -1, clockwiseRotation: 0, dpi: 72, format: .png, quality: 1),
                    .pageRaster(asset: asset, outputDescriptor: 4, pageIndex: 0, clockwiseRotation: 45, dpi: 72, format: .png, quality: 1)] {
        #expect(throws: WorkerProtocolError.self) { try WorkerRequest(operation: invalid) }
    }
    #expect(throws: WorkerProtocolError.self) { try WorkerResponse(id: UUID(), payload: .pageRaster(.init(bytes: 1, width: 9000, height: 9000, format: .png))) }
}

@Test func pdfRasterFlattensVisibleAnnotationAndFilledWidgetAppearances() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let blank = fixture.url("blank.pdf")
    do {
        var box = CGRect(x: 0, y: 0, width: 180, height: 240)
        let context = try #require(CGContext(blank as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
    }
    let document = try #require(PDFDocument(url: blank)), page = try #require(document.page(at: 0))
    page.setBounds(CGRect(x: 20, y: 30, width: 140, height: 180), for: .cropBox)
    let shape = PDFAnnotation(bounds: CGRect(x: 30, y: 170, width: 100, height: 20), forType: .square, withProperties: nil)
    shape.interiorColor = .red; shape.color = .red
    let hidden = PDFAnnotation(bounds: shape.bounds, forType: .square, withProperties: nil)
    hidden.interiorColor = .blue; hidden.color = .blue; hidden.shouldDisplay = false; hidden.shouldPrint = true
    let highlight = PDFAnnotation(bounds: CGRect(x: 30, y: 130, width: 100, height: 20), forType: .highlight, withProperties: nil)
    highlight.color = .yellow
    let text = PDFAnnotation(bounds: CGRect(x: 30, y: 90, width: 100, height: 25), forType: .freeText, withProperties: nil)
    text.contents = "VISIBLE"; text.font = .systemFont(ofSize: 15); text.fontColor = .black; text.color = .clear
    let widget = PDFAnnotation(bounds: CGRect(x: 30, y: 45, width: 100, height: 25), forType: .widget, withProperties: nil)
    widget.widgetFieldType = .text; widget.fieldName = "fixture-field"; widget.widgetStringValue = "FILLED"
    widget.font = .systemFont(ofSize: 15); widget.fontColor = .black; widget.backgroundColor = .white
    for annotation in [shape, hidden, highlight, text, widget] { annotation.userName = "Fileform fixture"; page.addAnnotation(annotation) }
    let input = fixture.url("annotations.pdf")
    #expect(document.write(to: input))
    let original = try Data(contentsOf: input)
    // Preserve the same authored appearance streams. PDFKit regenerates some
    // annotation appearances when saving after a rotation change. This equal-
    // length lexical edit changes only /Rotate and preserves every xref offset.
    var nativeData = original
    let rotateRange = try #require(nativeData.range(of: Data("/Rotate 0 /Annots".utf8)))
    nativeData.replaceSubrange(rotateRange, with: Data("/Rotate 90/Annots".utf8))
    #expect(nativeData.count == original.count)
    let nativeRotated = fixture.url("annotations-native-rotation.pdf")
    try nativeData.write(to: nativeRotated)
    #expect(PDFDocument(url: nativeRotated)?.page(at: 0)?.rotation == 90)
    let engine = rasterEngine()
    let plan = try await engine.plan(rasterRequest([input, nativeRotated], pages: [.init(sourceID: "s0", pageIndex: 0), .init(sourceID: "s0", pageIndex: 0, clockwiseRotation: 90), .init(sourceID: "s1", pageIndex: 0), .init(sourceID: "s0", pageIndex: 0, clockwiseRotation: 180), .init(sourceID: "s1", pageIndex: 0, clockwiseRotation: 90), .init(sourceID: "s0", pageIndex: 0, clockwiseRotation: 270), .init(sourceID: "s1", pageIndex: 0, clockwiseRotation: 180)], destination: fixture.url("annotations"), dpi: 144))
    let result = try await engine.run(plan), image = try rasterImage(result.artifacts[0].url)
    func darkPixels(_ rect: CGRect) throws -> Int {
        var count = 0
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 2) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 2) {
                if try rasterColor(image, x: x, y: y).allSatisfy({ $0 < 90 }) { count += 1 }
            }
        }
        return count
    }
    // Pixel coordinates measured from the rendered image's top-left.
    let red = try rasterColor(image, x: 60, y: 60), yellow = try rasterColor(image, x: 60, y: 140)
    #expect(red[0] > 240 && red[1] < 60 && red[2] < 60)
    #expect(yellow[0] > 230 && yellow[1] > 230 && yellow[2] < 60)
    #expect(try darkPixels(CGRect(x: 20, y: 190, width: 200, height: 50)) > 25)
    #expect(try darkPixels(CGRect(x: 20, y: 280, width: 200, height: 50)) > 25)
    let rotated = try rasterImage(result.artifacts[1].url)
    #expect(rotated.width == 360 && rotated.height == 280)
    let rotatedRed = try rasterColor(rotated, x: 300, y: 60)
    #expect(rotatedRed[0] > 240 && rotatedRed[1] < 60 && rotatedRed[2] < 60)
    for (extraIndex, nativeIndex) in [(1, 2), (3, 4), (5, 6)] {
        #expect(try Data(contentsOf: result.artifacts[extraIndex].url) == Data(contentsOf: result.artifacts[nativeIndex].url))
    }
    #expect(try Data(contentsOf: input) == original)
}

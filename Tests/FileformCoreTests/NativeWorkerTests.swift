// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import Testing
import ImageIO
import CoreGraphics
import PDFKit
import FileformDomain
@testable import FileformCore

@Test func nativeWorkerInspectsDescriptorWithoutMovingItsOffset() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image(name: "日本語.png", width: 123, height: 87)
    let source = open(input.path, O_RDONLY); defer { close(source) }
    #expect(source >= 3)
    #expect(lseek(source, 7, SEEK_SET) == 7)
    let before = try Data(contentsOf: input)
    let response = try NativeWorkerOperations.execute(.init(operation: .inspect(asset: .init(assetID: "source", descriptor: source))))
    guard case .inspection(let inspection) = response.payload else { Issue.record("Expected native inspection"); return }
    #expect(inspection.width == 123 && inspection.height == 87)
    #expect(try inspection.identity == FileSafety.identity(input))
    #expect(inspection.assetID == "source")
    #expect(lseek(source, 0, SEEK_CUR) == 7)
    #expect(try Data(contentsOf: input) == before)
    let encoded = try JSONEncoder().encode(response)
    #expect(!String(decoding: encoded, as: UTF8.self).contains(fixture.directory.path))
}

@Test func nativeWorkerWritesVerifiedPNGOnlyToScratchDescriptor() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image(alpha: true, width: 120, height: 80)
    let source = open(input.path, O_RDONLY); defer { close(source) }
    let outputURL = fixture.url("scratch")
    let output = open(outputURL.path, O_RDWR | O_CREAT | O_EXCL, 0o600); defer { close(output) }
    let original = try Data(contentsOf: input)
    let request = try WorkerRequest(operation: .preview(asset: .init(assetID: "source", descriptor: source),
                                                       outputDescriptor: output, maximumDimension: 60, pageIndex: nil))
    let response = try NativeWorkerOperations.execute(request)
    guard case .preview(let artifact) = response.payload else { Issue.record("Expected preview"); return }
    #expect(artifact.width == 60 && artifact.height == 40)
    #expect(artifact.bytes == Int64(try Data(contentsOf: outputURL).count))
    let imageSource = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
    #expect(CGImageSourceGetType(imageSource) as String? == "public.png")
    let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    #expect(image.width == 60 && image.height == 40)
    #expect(try Data(contentsOf: input) == original)
}

@Test func nativeWorkerRejectsSourceAliasesNonemptyScratchAndNonregularInputs() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let original = try Data(contentsOf: input)
    let source = open(input.path, O_RDONLY); defer { close(source) }
    let alias = open(input.path, O_RDWR); defer { close(alias) }
    let occupied = fixture.url("occupied"); try Data("keep me".utf8).write(to: occupied)
    let occupiedFD = open(occupied.path, O_RDWR); defer { close(occupiedFD) }
    for output in [alias, occupiedFD] {
        let request = try WorkerRequest(operation: .preview(asset: .init(assetID: "source", descriptor: source),
                                                           outputDescriptor: output, maximumDimension: 50, pageIndex: nil))
        let result = try NativeWorkerOperations.execute(request)
        guard case .failure(.invalidInput) = result.payload else { Issue.record("Unsafe output accepted"); continue }
    }
    #expect(try Data(contentsOf: input) == original)
    #expect(try String(contentsOf: occupied, encoding: .utf8) == "keep me")
    let directory = open(fixture.directory.path, O_RDONLY); defer { close(directory) }
    let result = try NativeWorkerOperations.execute(.init(operation: .inspect(asset: .init(assetID: "source", descriptor: directory))))
    guard case .failure(.permissionDenied) = result.payload else { Issue.record("Directory accepted"); return }
}

@Test func nativeWorkerRejectsOversizedSparseAndMalformedSources() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let large = open(fixture.url("large").path, O_RDWR | O_CREAT | O_EXCL, 0o600); defer { close(large) }
    #expect(ftruncate(large, off_t(NativeWorkerOperations.maximumInputBytes + 1)) == 0)
    let tooLarge = try NativeWorkerOperations.execute(.init(operation: .inspect(asset: .init(assetID: "source", descriptor: large))))
    guard case .failure(.resourceLimit) = tooLarge.payload else { Issue.record("Size bound not enforced"); return }
    let bad = fixture.url("bad"); try Data("not an image".utf8).write(to: bad)
    let descriptor = open(bad.path, O_RDONLY); defer { close(descriptor) }
    let malformed = try NativeWorkerOperations.execute(.init(operation: .inspect(asset: .init(assetID: "source", descriptor: descriptor))))
    guard case .failure(.unsupportedInput) = malformed.payload else { Issue.record("Malformed source accepted"); return }
}

@Test func nativeWorkerPDFPreviewRespectsRotationAndNonzeroOrigin() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let original = fixture.url("original.pdf")
    var box = CGRect(x: 20, y: 30, width: 200, height: 100)
    let consumer = try #require(CGDataConsumer(url: original as CFURL))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 20, y: 30, width: 100, height: 100))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 120, y: 30, width: 100, height: 100))
    context.endPDFPage(); context.closePDF()
    let document = try #require(PDFDocument(url: original))
    let page = try #require(document.page(at: 0)); page.rotation = 90
    let rotated = fixture.url("rotated.pdf")
    #expect(document.write(to: rotated))
    let source = open(rotated.path, O_RDONLY); defer { close(source) }
    let outputURL = fixture.url("preview.png")
    let output = open(outputURL.path, O_RDWR | O_CREAT | O_EXCL, 0o600); defer { close(output) }
    let response = try NativeWorkerOperations.execute(.init(operation: .preview(asset: .init(assetID: "pdf", descriptor: source),
        outputDescriptor: output, maximumDimension: 100, pageIndex: 0)))
    guard case .preview(let result) = response.payload else { Issue.record("Expected PDF preview"); return }
    #expect(result.width == 50 && result.height == 100)
    let decoded = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(image.width == 50 && image.height == 100)
    // Both halves survive the translated box; a misplaced drawing transform
    // would leave part or all of this portrait preview white.
    let pixels = try #require(CGContext(data: nil, width: 50, height: 100, bitsPerComponent: 8,
        bytesPerRow: 200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    pixels.draw(image, in: CGRect(x: 0, y: 0, width: 50, height: 100))
    let data = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
    let top = (25 * 50 + 25) * 4
    let bottom = (75 * 50 + 25) * 4
    #expect(abs(Int(data[top]) - Int(data[bottom])) > 200)
    #expect(abs(Int(data[top + 2]) - Int(data[bottom + 2])) > 200)
}

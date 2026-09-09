// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Testing
import FileformDomain
@testable import FileformCore

private let quadrantColors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]

private func quadrantFixture(_ fixture: Fixture, orientation: Int) throws -> URL {
    let width = 80, height = 48
    var bytes = [UInt8]()
    for y in 0..<height {
        for x in 0..<width { bytes.append(contentsOf: quadrantColors[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]) }
    }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let color = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: color,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let url = fixture.url("quadrants-\(orientation).png")
    let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(writer))
    return url
}

private func cropPlan(input: URL, output: URL, rectangle: PixelCrop, format: OutputFormat = .png,
                      goal: ConversionGoal = .convert, options: ConversionOptions = .init(),
                      collision: CollisionPolicy = .fail) throws -> TransformationPlan {
    let inspection = try ImageBackend.inspect(input, identity: FileSafety.identity(input))
    let request = try TransformationRequest(assets: [.init(id: "image", url: input)],
                                           operation: .imageCrop(rectangle: rectangle, conversion: .init(goal: goal, options: options)),
                                           output: .init(destination: output, format: format), collisionPolicy: collision)
    return try ImageTransformationBackend.plan(request: request, inspection: inspection)
}

private func decodedCrop(_ url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
}

private func centerPixel(_ image: CGImage) throws -> [UInt8] {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                       bytesPerRow: image.width * 4, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let offset = ((image.height / 2) * image.width + image.width / 2) * 4
    return Array(UnsafeBufferPointer(start: bytes.advanced(by: offset), count: 4))
}

@Test(arguments: Array(1...8))
func imageCropUsesTopLeftOrientedCoordinatesExactlyOnce(_ orientation: Int) throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try quadrantFixture(fixture, orientation: orientation)
    let before = SHA256.hash(data: try Data(contentsOf: input))
    // Independent EXIF corner mapping: displayed TL, TR, BL, BR -> encoded quadrant.
    let expected = [[0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
                    [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2]][orientation - 1]
    let width = orientation >= 5 ? 48 : 80
    let height = orientation >= 5 ? 80 : 48
    for corner in 0..<4 {
        let rectangle = PixelCrop(x: corner % 2 == 0 ? 3 : width - 13,
                                  y: corner < 2 ? 3 : height - 13, width: 10, height: 10)
        let plan = try cropPlan(input: input, output: fixture.url("corner-\(corner).png"), rectangle: rectangle)
        let result = try ImageTransformationBackend.execute(plan: plan, progress: { _ in })
        let image = try decodedCrop(#require(result.artifacts.first).url)
        #expect(image.width == 10 && image.height == 10)
        #expect(try centerPixel(image) == quadrantColors[expected[corner]])
    }
    #expect(SHA256.hash(data: try Data(contentsOf: input)) == before)
}

@Test func imageCropRunsBeforeResizeAndNeverUpscales() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try quadrantFixture(fixture, orientation: 1)
    let crop = PixelCrop(x: 42, y: 3, width: 32, height: 16)
    for bound in [8, 128] {
        let plan = try cropPlan(input: input, output: fixture.url("size-\(bound).png"), rectangle: crop,
                                options: .init(maxDimension: bound))
        let result = try ImageTransformationBackend.execute(plan: plan, progress: { _ in })
        let image = try decodedCrop(#require(result.artifacts.first).url)
        #expect(image.width == (bound == 8 ? 8 : 32))
        #expect(image.height == (bound == 8 ? 4 : 16))
        #expect(try centerPixel(image) == quadrantColors[1])
    }
    #expect(throws: FileformError.self) {
        try cropPlan(input: input, output: fixture.url("outside.png"), rectangle: .init(x: 79, y: 0, width: 2, height: 1))
    }
}

@Test func imageCropRequiresExplicitFlatteningAndRetainsAlpha() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image(alpha: true, width: 80, height: 48)
    let crop = PixelCrop(x: 3, y: 3, width: 32, height: 24)
    #expect(throws: FileformError.self) {
        try cropPlan(input: input, output: fixture.url("forbidden.jpg"), rectangle: crop, format: .jpeg)
    }
    let png = try cropPlan(input: input, output: fixture.url("alpha.png"), rectangle: crop)
    let pngResult = try ImageTransformationBackend.execute(plan: png, progress: { _ in })
    let transparent = try centerPixel(decodedCrop(#require(pngResult.artifacts.first).url))
    #expect((126...129).contains(Int(transparent[3])))
    var colors: [[UInt8]] = []
    for background in [AlphaBackground.black, .white] {
        let plan = try cropPlan(input: input, output: fixture.url("\(background.rawValue).jpg"), rectangle: crop,
                                format: .jpeg, options: .init(quality: 1, background: background))
        let result = try ImageTransformationBackend.execute(plan: plan, progress: { _ in })
        colors.append(try centerPixel(decodedCrop(#require(result.artifacts.first).url)))
    }
    #expect(colors.allSatisfy { $0[3] == 255 })
    for channel in 0..<3 { #expect(Int(colors[1][channel]) - Int(colors[0][channel]) > 110) }
}

@Test func imageCropFitsExactBytesOrPublishesNothing() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try quadrantFixture(fixture, orientation: 1)
    let crop = PixelCrop(x: 2, y: 2, width: 70, height: 40)
    let baseline = try cropPlan(input: input, output: fixture.url("baseline.png"), rectangle: crop)
    let initial = try ImageTransformationBackend.execute(plan: baseline, progress: { _ in })
    let budget = try #require(initial.artifacts.first).bytes
    let exact = try cropPlan(input: input, output: fixture.url("exact.png"), rectangle: crop, goal: .fit,
                             options: .init(maximumBytes: budget))
    let fitted = try ImageTransformationBackend.execute(plan: exact, progress: { _ in })
    #expect(try #require(fitted.artifacts.first).bytes == budget)
    for format in [OutputFormat.png, .jpeg] {
        let destination = fixture.url("impossible.\(format.fileExtension)")
        let plan = try cropPlan(input: input, output: destination, rectangle: crop, format: format, goal: .fit,
                                options: .init(maximumBytes: 1))
        do { _ = try ImageTransformationBackend.execute(plan: plan, progress: { _ in }); Issue.record("Impossible crop size succeeded") }
        catch let failure as FileformError { #expect(failure.code == .targetUnmet) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".fileform-") })
}

@Test func imageCropPreservesRacingDestinationAndCleansOwnedStaging() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try quadrantFixture(fixture, orientation: 1)
    let before = SHA256.hash(data: try Data(contentsOf: input))
    let destination = fixture.url("existing.png")
    let other = Data("another writer".utf8)
    let plan = try cropPlan(input: input, output: destination, rectangle: .init(x: 1, y: 1, width: 20, height: 20))
    do {
        _ = try ImageTransformationBackend.execute(plan: plan) { event in
            if event.phase == .saving { try? other.write(to: destination, options: .withoutOverwriting) }
        }
        Issue.record("Crop overwrote a racing destination")
    } catch let failure as FileformError { #expect(failure.code == .destinationExists) }
    #expect(try Data(contentsOf: destination) == other)
    let rename = try cropPlan(input: input, output: destination, rectangle: .init(x: 1, y: 1, width: 20, height: 20), collision: .rename)
    let renamed = try ImageTransformationBackend.execute(plan: rename, progress: { _ in })
    #expect(try #require(renamed.artifacts.first).url.lastPathComponent == "existing-1.png")
    #expect(SHA256.hash(data: try Data(contentsOf: input)) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".fileform-") })
}

@Test func imageCropRejectsChangedSourceAndUnsupportedPreservation() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try quadrantFixture(fixture, orientation: 1)
    let inspection = try ImageBackend.inspect(input, identity: FileSafety.identity(input))
    let crop = PixelCrop(x: 1, y: 1, width: 10, height: 10)
    for (conversion, fidelity) in [(ConversionParameters(color: .preserve), FidelityPolicy.allowDeclaredLosses),
                                   (.init(metadata: .preserve), .allowDeclaredLosses), (.init(), .requireLossless)] {
        let request = try TransformationRequest(assets: [.init(id: "image", url: input)],
                                               operation: .imageCrop(rectangle: crop, conversion: conversion),
                                               output: .init(destination: fixture.url("never.png"), format: .png), fidelity: fidelity)
        #expect(throws: FileformError.self) { try ImageTransformationBackend.plan(request: request, inspection: inspection) }
    }
    let plan = try cropPlan(input: input, output: fixture.url("changed.png"), rectangle: crop)
    try Data("replaced source".utf8).write(to: input)
    do { _ = try ImageTransformationBackend.execute(plan: plan, progress: { _ in }); Issue.record("Changed source was accepted") }
    catch let failure as FileformError { #expect(failure.code == .inputChanged) }
    #expect(!FileManager.default.fileExists(atPath: fixture.url("changed.png").path))
}

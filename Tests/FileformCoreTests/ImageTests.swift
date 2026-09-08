// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import ImageIO
import Testing
import FileformDomain
@testable import FileformCore

struct Fixture {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fileform-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func image(name: String = "input.png", alpha: Bool = false, orientation: Int = 1,
               width: Int = 320, height: Int = 240) throws -> URL {
        let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: alphaInfo.rawValue))
        for y in 0..<height {
            context.setFillColor(CGColor(red: CGFloat(y % 37) / 36, green: CGFloat(y % 17) / 16, blue: 0.4, alpha: alpha ? 0.5 : 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url(name) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url(name)
    }
}

@Test func conversionReopensAndPreservesOriginal() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image(name: "a space ' quote 日本語.png")
    let before = try Data(contentsOf: input)
    let engine = ConversionEngine()
    let plan = try await engine.plan(.init(input: input, destination: fixture.url("out.jpg"), format: .jpeg))
    let result = try await engine.run(plan)
    #expect(result.status == .succeeded)
    let output = try #require(result.output)
    let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 320 && image.height == 240)
    #expect(try Data(contentsOf: input) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".fileform-") })
}

@Test func alphaNeedsExplicitFlattening() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image(alpha: true)
    let engine = ConversionEngine()
    await #expect(throws: FileformError.self) {
        try await engine.plan(.init(input: input, destination: fixture.url("out.jpg"), format: .jpeg))
    }
    let pngPlan = try await engine.plan(.init(input: input, destination: fixture.url("out.png"), format: .png))
    let result = try await engine.run(pngPlan)
    #expect(result.status == .succeeded)
    let jpgPlan = try await engine.plan(.init(input: input, destination: fixture.url("out.jpg"), format: .jpeg,
                                             options: .init(background: .white)))
    #expect(try await engine.run(jpgPlan).status == .succeeded)
}

@Test func fitsExactBudgetOrPublishesNothing() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let engine = ConversionEngine()
    let impossible = try await engine.plan(.init(input: input, destination: fixture.url("impossible.jpg"), format: .jpeg,
                                                goal: .fit, options: .init(maximumBytes: 10)))
    do { _ = try await engine.run(impossible); Issue.record("Expected target_unmet") }
    catch let error as FileformError { #expect(error.code == .targetUnmet) }
    #expect(!FileManager.default.fileExists(atPath: fixture.url("impossible.jpg").path))
    let possible = try await engine.plan(.init(input: input, destination: fixture.url("possible.jpg"), format: .jpeg,
                                              goal: .fit, options: .init(maximumBytes: 100_000)))
    let result = try await engine.run(possible)
    #expect(try #require(result.outputBytes) <= 100_000)
}

@Test func originalDestinationAndChangedInputAreRejected() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let engine = ConversionEngine()
    await #expect(throws: FileformError.self) { try await engine.plan(.init(input: input, destination: input, format: .png)) }
    let plan = try await engine.plan(.init(input: input, destination: fixture.url("out.png"), format: .png))
    try Data("changed".utf8).write(to: input)
    do { _ = try await engine.run(plan); Issue.record("Expected input_changed") }
    catch let error as FileformError { #expect(error.code == .inputChanged) }
    #expect(!FileManager.default.fileExists(atPath: fixture.url("out.png").path))
}

@Test func commitDoesNotClobberRacingDestination() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let transaction = try OutputTransaction(destination: fixture.url("out.png"), input: input, collisionPolicy: .fail)
    defer { transaction.cleanup() }
    let candidate = transaction.candidate(0, format: .png)
    try Data("candidate".utf8).write(to: candidate)
    let other = Data("other writer".utf8)
    try other.write(to: fixture.url("out.png"))
    #expect(throws: FileformError.self) { try transaction.commit(candidate) }
    #expect(try Data(contentsOf: fixture.url("out.png")) == other)
}

@Test func renameCollisionRetainsBothOutputs() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let originalOutput = Data("existing result".utf8)
    try originalOutput.write(to: fixture.url("out.png"))
    let engine = ConversionEngine()
    let plan = try await engine.plan(.init(input: input, destination: fixture.url("out.png"), format: .png, collisionPolicy: .rename))
    let result = try await engine.run(plan)
    #expect(result.output?.lastPathComponent == "out-1.png")
    #expect(try Data(contentsOf: fixture.url("out.png")) == originalOutput)
}

@Test func downscaleIsExplicitAndBounded() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let engine = ConversionEngine()
    let plan = try await engine.plan(.init(input: input, destination: fixture.url("small.png"), format: .png,
                                           options: .init(maxDimension: 80)))
    let result = try await engine.run(plan)
    let info = try await engine.inspect(#require(result.output))
    #expect(info.width == 80 && info.height == 60)
}

@Test func invalidAndCancelledInputsDoNotPublish() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    try Data("not an image".utf8).write(to: fixture.url("fake.png"))
    let engine = ConversionEngine()
    await #expect(throws: FileformError.self) { try await engine.inspect(fixture.url("fake.png")) }
    let input = try fixture.image()
    let plan = try await engine.plan(.init(input: input, destination: fixture.url("cancelled.png"), format: .png))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await engine.run(plan)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: fixture.url("cancelled.png").path))
}

@Test(arguments: Array(1...8))
func orientationIsAppliedToOutputDimensions(_ orientation: Int) async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image(orientation: orientation)
    let engine = ConversionEngine()
    let plan = try await engine.plan(.init(input: input, destination: fixture.url("oriented.png"), format: .png))
    #expect(plan.inspection.orientation == orientation)
    let result = try await engine.run(plan)
    let output = try #require(result.output)
    let info = try await engine.inspect(output)
    #expect(info.orientation == 1)
    #expect(info.width == (orientation >= 5 ? 240 : 320))
    #expect(info.height == (orientation >= 5 ? 320 : 240))
}

@Test func truncatedImageIsNotPublished() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let engine = ConversionEngine()
    let jpeg = try await engine.plan(.init(input: input, destination: fixture.url("complete.jpg"), format: .jpeg))
    let result = try await engine.run(jpeg)
    let data = try Data(contentsOf: #require(result.output))
    let broken = fixture.url("truncated.jpg")
    try Data(data.prefix(data.count / 2)).write(to: broken)
    do {
        let plan = try await engine.plan(.init(input: broken, destination: fixture.url("must-not-exist.png"), format: .png))
        _ = try await engine.run(plan)
        Issue.record("A truncated image should not be published")
    } catch {}
    #expect(!FileManager.default.fileExists(atPath: fixture.url("must-not-exist.png").path))
}

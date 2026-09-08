// Copyright 2026 Amaan Gokak and Fileform Core contributors
// SPDX-License-Identifier: Apache-2.0
// Feasibility probe only; not the production conversion pipeline.

import Foundation
import CoreGraphics
import ImageIO

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func encode(_ image: CGImage, type: String, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
        throw ProbeFailure("Could not create destination for \(type)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ProbeFailure("Could not finalize \(type)")
    }
}

func decode(_ url: URL, expectedType: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let type = CGImageSourceGetType(source), type as String == expectedType,
          CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == 32, image.height == 24 else {
        throw ProbeFailure("Reopened output failed type, frame-count or dimension verification")
    }
    return image
}

func pixels(_ image: CGImage) throws -> Data {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: 32, height: 24,
                                  bitsPerComponent: 8, bytesPerRow: 32 * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw ProbeFailure("Could not allocate comparison buffer")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 24))
    guard let data = context.data else { throw ProbeFailure("Missing comparison pixels") }
    return Data(bytes: data, count: 32 * 24 * 4)
}

func run() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fileform-imageio-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: 32, height: 24,
                                  bitsPerComponent: 8, bytesPerRow: 32 * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw ProbeFailure("Could not allocate synthetic fixture")
    }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
    guard let fixture = context.makeImage() else { throw ProbeFailure("Could not create fixture") }

    let input = directory.appendingPathComponent("fixture.png")
    let output = directory.appendingPathComponent("roundtrip.tiff")
    try encode(fixture, type: "public.png", to: input)
    let originalBytes = try Data(contentsOf: input)
    let decodedInput = try decode(input, expectedType: "public.png")
    try encode(decodedInput, type: "public.tiff", to: output)
    let decodedOutput = try decode(output, expectedType: "public.tiff")
    guard try pixels(fixture) == pixels(decodedInput),
          try pixels(decodedInput) == pixels(decodedOutput),
          try Data(contentsOf: input) == originalBytes else {
        throw ProbeFailure("Pixels or original bytes changed during the round trip")
    }

    let report: [String: Any] = [
        "schemaVersion": 1,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "imageIOReaders": (CGImageSourceCopyTypeIdentifiers() as! [String]).sorted(),
        "imageIOWriters": (CGImageDestinationCopyTypeIdentifiers() as! [String]).sorted(),
        "probe": [
            "route": "synthetic opaque sRGB PNG -> TIFF", "status": "passed",
            "width": 32, "height": 24, "decodedPixelsEqual": true,
            "originalBytesUnchanged": true, "outputBytes": try Data(contentsOf: output).count
        ],
        "limitation": "Runtime inventory and one synthetic route only; not a production support matrix."
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("ImageIO probe failed: \(error)\n".utf8))
    exit(1)
}

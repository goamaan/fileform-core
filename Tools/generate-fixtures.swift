// SPDX-License-Identifier: Apache-2.0
// Generates synthetic, redistributable files for CLI and GUI verification.
import Foundation
import CoreGraphics
import ImageIO

guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift Tools/generate-fixtures.swift <empty-output-directory>") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { fatalError("Fixture directory must be empty; existing files are never replaced.") }

func image(name: String, alpha: Bool, orientation: Int = 1) throws {
    let width = 1024, height = 768
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
    for row in 0..<height {
        let position = CGFloat(row) / CGFloat(height)
        context.setFillColor(CGColor(red: 0.12 + position * 0.15, green: 0.25 + position * 0.45, blue: 0.9 - position * 0.35, alpha: alpha ? 0.6 : 1))
        context.fill(CGRect(x: 0, y: row, width: width, height: 1))
    }
    for index in 0..<6 {
        context.setFillColor(CGColor(red: 0.75, green: 0.87, blue: 1, alpha: 0.3 + CGFloat(index) * 0.08))
        context.fill(CGRect(x: 100 + index * 135, y: 130, width: 80, height: 90 + index * 80))
    }
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not encode fixture") }
}
try image(name: "Studio chart.png", alpha: false)
try image(name: "Transparent chart.png", alpha: true)
try image(name: "Rotated chart.png", alpha: false, orientation: 6)
try Data("This is deliberately not a valid image.".utf8).write(to: directory.appendingPathComponent("Damaged image.jpg"), options: .withoutOverwriting)

var wave = Data()
func text(_ value: String) { wave.append(contentsOf: value.utf8) }
func integer<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) } }
let samples = 48_000 * 4
text("RIFF"); integer(UInt32(36 + samples * 4)); text("WAVEfmt "); integer(UInt32(16))
integer(UInt16(1)); integer(UInt16(2)); integer(UInt32(48_000)); integer(UInt32(48_000 * 4))
integer(UInt16(4)); integer(UInt16(16)); text("data"); integer(UInt32(samples * 4))
for index in 0..<samples {
    let value = Int16(sin(Double(index) / 48_000 * 440 * 2 * .pi) * 10_000)
    integer(value); integer(value)
}
try wave.write(to: directory.appendingPathComponent("Studio tone.wav"), options: .withoutOverwriting)
print("Generated synthetic fixtures at \(directory.path)")

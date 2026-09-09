// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import ImageIO
import FileformDomain

/// Called only in the isolated worker; input is bounded encoded JPEG or planes of
/// exact 8-bit color samples followed by same-size grayscale alpha samples.
enum PDFEmbeddedImageEncoder {
    static func encode(_ input: URL, destination: URL, width: Int, height: Int, channels: Int, hasAlpha: Bool, encodedJPEG: Bool) throws {
        let pixels = width * height
        let count = try FileSafety.identity(input).bytes
        guard count <= 256 * 1024 * 1024 else { throw FileformError(.resourceLimit, "Extracted stream exceeds 256 MiB.") }
        if encodedJPEG {
            guard count > 0, let source = CGImageSourceCreateWithURL(input as CFURL, nil),
                  CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == width,
                  properties[kCGImagePropertyPixelHeight] as? Int == height,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  image.width == width, image.height == height, image.bitsPerComponent == 8,
                  image.colorSpace?.numberOfComponents == channels else { throw FileformError(.verificationFailed, "JPEG stream does not match its PDF image dictionary.") }
            guard (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else { throw FileformError(.unsupported, "JPEG orientation metadata requires unsupported PDF interpretation.") }
            try ImageIntegrity.validateEndRecord(input, type: "public.jpeg", byteCount: count)
            try FileManager.default.copyItem(at: input, to: destination)
            return
        }
        guard count == Int64(pixels * (channels + (hasAlpha ? 1 : 0))) else { throw FileformError(.verificationFailed, "Decoded image or alpha sample count is incorrect.") }
        let samples = try Data(contentsOf: input)
        var rgba = Data(count: pixels * 4)
        rgba.withUnsafeMutableBytes { destination in
            let out = destination.bindMemory(to: UInt8.self)
            samples.withUnsafeBytes { source in
                let bytes = source.bindMemory(to: UInt8.self)
                for i in 0..<pixels {
                    out[i * 4] = bytes[i * channels]
                    out[i * 4 + 1] = bytes[i * channels + (channels == 3 ? 1 : 0)]
                    out[i * 4 + 2] = bytes[i * channels + (channels == 3 ? 2 : 0)]
                    out[i * 4 + 3] = hasAlpha ? bytes[pixels * channels + i] : 255
                }
            }
        }
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let encoder = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else { throw FileformError(.resourceLimit, "Image allocation failed.") }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder), let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
              let result = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete, result.width == width, result.height == height,
              result.bitsPerComponent == 8, result.bitsPerPixel == 32, result.bytesPerRow == width * 4,
              result.alphaInfo == .last, let decoded = result.dataProvider?.data, decoded as Data == rgba else { throw FileformError(.verificationFailed, "PNG did not preserve exact straight RGBA samples.") }
        try ImageIntegrity.validateEndRecord(destination, type: "public.png", byteCount: FileSafety.identity(destination).bytes)
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import ImageIO
import FileformDomain

enum ImageBackend {
    static let maximumPixels: Int64 = 80_000_000
    static let formats: [OutputFormat] = [.jpeg, .png, .tiff]

    static func canRead(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return CGImageSourceGetType(source) != nil
    }

    static func inspect(_ url: URL, identity: FileIdentity) throws -> Inspection {
        guard identity.bytes <= 512 * 1024 * 1024 else {
            throw FileformError(.resourceLimit, "This image exceeds the current 512 MB input limit.")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw FileformError(.unsupported, "This image could not be inspected. It may be damaged or unsupported.")
        }
        try ImageIntegrity.validateEndRecord(url, type: type as String, byteCount: identity.bytes)
        guard width <= Int(maximumPixels), height <= Int(maximumPixels),
              Int64(width) * Int64(height) <= maximumPixels else {
            throw FileformError(.resourceLimit, "This image exceeds the current 80-megapixel decoding limit.")
        }
        let count = CGImageSourceGetCount(source)
        var warnings = [String]()
        if count != 1 { warnings.append("Animated or multi-page image conversion is not supported yet.") }
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        if depth > 8 { warnings.append("High-bit-depth images require a preservation workflow that is not available yet.") }
        var gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        if #available(macOS 15, *) {
            gainMap = gainMap || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        }
        if gainMap { warnings.append("HDR gain-map preservation is not supported yet.") }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard (1...8).contains(orientation) else { throw FileformError(.unsupported, "This image has an invalid orientation.") }
        return .init(input: url, identity: identity, family: .image, detectedType: type as String,
                     width: width, height: height, frameCount: count,
                     hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
                     bitDepth: depth, orientation: orientation, warnings: warnings)
    }

    static func capabilities() -> [Capability] {
        let writers = CGImageDestinationCopyTypeIdentifiers() as! [String]
        return formats.map { format in
            .init(format: format, goals: [.convert, .compress, .fit], engine: "imageio",
                  available: format.imageType.map(writers.contains) ?? false,
                  limitation: format.isLossyImage ? "SDR still images; quality can change." : "Lossless output may be larger. Fit-size can be infeasible.")
        }
    }

    static func validate(_ inspection: Inspection, request: ConversionRequest) throws {
        guard inspection.frameCount == 1, inspection.bitDepth ?? 8 <= 8, inspection.warnings.isEmpty else {
            throw FileformError(.unsupported, inspection.warnings.first ?? "This image needs a preservation workflow not yet supported.")
        }
        guard formats.contains(request.format) else { throw FileformError(.unsupported, "This image output is not implemented.") }
        if inspection.hasAlpha == true && !request.format.supportsAlpha && request.options.background == nil {
            throw FileformError(.invalidRequest, "This image has transparency. Choose a white or black background for JPEG, or use PNG/TIFF.")
        }
    }

    static func render(_ inspection: Inspection, options: ConversionOptions, format: OutputFormat) throws -> CGImage {
        try Task.checkCancellation()
        guard let width = inspection.width, let height = inspection.height,
              let source = CGImageSourceCreateWithURL(inspection.input as CFURL, nil) else {
            throw FileformError(.ioFailure, "The image is no longer readable.")
        }
        let bound = min(options.maxDimension ?? max(width, height), max(width, height))
        let properties: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bound,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, properties as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw FileformError(.unsupported, "This image could not be fully decoded. It may be truncated or damaged.")
        }
        guard image.bitsPerComponent <= 8 else {
            throw FileformError(.unsupported, "High-bit-depth image conversion is not available yet.")
        }
        let alphaInfo: CGImageAlphaInfo = format.supportsAlpha ? .premultipliedLast : .noneSkipLast
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: alphaInfo.rawValue) else {
            throw FileformError(.resourceLimit, "There is not enough memory to prepare this image.")
        }
        context.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if !format.supportsAlpha {
            let value: CGFloat = options.background == .black ? 0 : 1
            context.setFillColor(CGColor(gray: value, alpha: 1)); context.fill(rect)
        }
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw FileformError(.engineFailed, "Could not prepare the image.") }
        try Task.checkCancellation()
        return result
    }

    static func encode(_ image: CGImage, format: OutputFormat, quality: Double, destination: URL, dpi: Int? = nil) throws {
        guard let type = format.imageType,
              let writer = CGImageDestinationCreateWithURL(destination as CFURL, type as CFString, 1, nil) else {
            throw FileformError(.engineUnavailable, "This Mac cannot write the selected image format.")
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality,
                                          kCGImagePropertyOrientation: 1]
        if let dpi { properties[kCGImagePropertyDPIWidth] = dpi; properties[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            throw FileformError(.engineFailed, "Image encoding failed. Check available memory and disk space.")
        }
    }

    static func verify(_ url: URL, format: OutputFormat, rendered: CGImage, preserveAlpha: Bool) throws -> Int64 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source), type as String == format.imageType,
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == rendered.width, image.height == rendered.height else {
            throw FileformError(.verificationFailed, "The encoded image failed format, completeness or dimension checks.")
        }
        if preserveAlpha {
            let alphaModes: [CGImageAlphaInfo] = [.first, .last, .premultipliedFirst, .premultipliedLast]
            guard alphaModes.contains(image.alphaInfo) else {
                throw FileformError(.verificationFailed, "The output did not retain its transparency channel.")
            }
        }
        return try FileSafety.identity(url).bytes
    }
}

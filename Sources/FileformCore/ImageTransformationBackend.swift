// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import FileformDomain

/// Oriented pixel crop followed by an optional explicit downscale. The caller
/// serializes expensive jobs; this adapter owns verification and publication.
enum ImageTransformationBackend {
    static func plan(request: TransformationRequest, inspection: Inspection) throws -> TransformationPlan {
        try request.validate()
        guard case .imageCrop(let crop, let conversion) = request.operation,
              request.assets.count == 1, inspection.family == .image,
              inspection.input == request.assets[0].url.standardizedFileURL else {
            throw FileformError(.invalidRequest, "Image cropping requires one inspected still image.")
        }
        guard conversion.color == .convertToSRGB, conversion.metadata == .removeDescriptive,
              request.fidelity == .allowDeclaredLosses else {
            throw FileformError(.unsupported, "This crop route does not yet support preserving profiles, metadata or a lossless fidelity guarantee.")
        }
        guard conversion.options.pageNumber == nil else {
            throw FileformError(.invalidRequest, "Page selection does not apply to image cropping.")
        }
        let legacy = ConversionRequest(input: request.assets[0].url, destination: request.output.destination,
                                       format: request.output.format, goal: conversion.goal,
                                       options: conversion.options, collisionPolicy: request.collisionPolicy)
        try ImageBackend.validate(inspection, request: legacy)
        guard ImageBackend.capabilities().contains(where: { $0.format == request.output.format && $0.available }),
              let width = inspection.width, let height = inspection.height else {
            throw FileformError(.engineUnavailable, "The selected image writer is unavailable.")
        }
        let sideways = (5...8).contains(inspection.orientation ?? 1)
        try crop.validate(sourceWidth: sideways ? height : width, sourceHeight: sideways ? width : height)
        try FileSafety.verifyUnchanged(inspection)
        try FileSafety.rejectSourceAliases(destination: request.output.destination, inputs: [inspection])
        var warnings = ["Crop coordinates use the oriented image, with the origin at the top left.",
                        "Output uses standard sRGB color. Descriptive metadata, including location, is removed."]
        if request.output.format.isLossyImage { warnings.append("JPEG is lossy; the output may lose image detail.") }
        if inspection.hasAlpha == true && !request.output.format.supportsAlpha {
            warnings.append("Transparency will be flattened onto the selected background.")
        }
        if let bound = conversion.options.maxDimension, bound < max(crop.width, crop.height) {
            warnings.append("The cropped image will be resized to fit within \(bound) pixels on its longest edge.")
        }
        return .init(request: request, inputs: [.init(id: request.assets[0].id, inspection: inspection)], warnings: warnings)
    }

    static func execute(plan: TransformationPlan, progress: @Sendable (ProgressEvent) -> Void) throws -> TransformationResult {
        try Task.checkCancellation()
        guard plan.schemaVersion == 1, plan.inputs.count == 1, plan.request.assets.count == 1,
              plan.inputs[0].id == plan.request.assets[0].id,
              plan.inputs[0].inspection.input == plan.request.assets[0].url.standardizedFileURL else {
            throw FileformError(.invalidRequest, "The crop plan does not match its source bindings.")
        }
        let recorded = plan.inputs[0].inspection
        try FileSafety.verifyUnchanged(recorded)
        // Serialized inspection properties are untrusted: reread content before
        // calculating bounds or rendering, rather than trusting supplied sizes.
        let inspection = try ImageBackend.inspect(recorded.input, identity: FileSafety.identity(recorded.input))
        guard inspection.identity == recorded.identity else { throw FileformError(.inputChanged, "The crop source changed.") }
        let validated = try self.plan(request: plan.request, inspection: inspection)
        guard case .imageCrop(let crop, let conversion) = validated.request.operation else {
            throw FileformError(.invalidRequest, "Expected an image crop plan.")
        }
        let request = validated.request
        let options = conversion.options
        progress(.init(.preparing))
        let transaction = try OutputTransaction(destination: request.output.destination, input: inspection.input,
                                                collisionPolicy: request.collisionPolicy)
        defer { transaction.cleanup() }
        var renderOptions = options
        renderOptions.maxDimension = nil
        let oriented = try ImageBackend.render(inspection, options: renderOptions, format: request.output.format)
        try crop.validate(sourceWidth: oriented.width, sourceHeight: oriented.height)
        guard let cropped = oriented.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)) else {
            throw FileformError(.engineFailed, "The selected image rectangle could not be cropped.")
        }
        let rendered = try resize(cropped, maximumDimension: options.maxDimension, alpha: request.output.format.supportsAlpha)
        let qualities: [Double]
        if conversion.goal == .fit && request.output.format.isLossyImage {
            qualities = (0...10).map { options.quality - Double($0) / 10 * (options.quality - options.minimumQuality) }
        } else { qualities = [options.quality] }
        for (attempt, quality) in qualities.enumerated() {
            try Task.checkCancellation()
            progress(.init(.encoding))
            let candidate = transaction.candidate(attempt, format: request.output.format)
            try ImageBackend.encode(rendered, format: request.output.format, quality: quality, destination: candidate)
            try Task.checkCancellation()
            progress(.init(.verifying))
            let bytes = try ImageBackend.verify(candidate, format: request.output.format, rendered: rendered,
                                                preserveAlpha: inspection.hasAlpha == true && request.output.format.supportsAlpha)
            if conversion.goal == .fit, let limit = options.maximumBytes, bytes > limit {
                try FileManager.default.removeItem(at: candidate)
                continue
            }
            if conversion.goal == .compress && bytes >= inspection.identity.bytes {
                try FileSafety.verifyUnchanged(inspection)
                return .init(operationID: .imageCrop, status: .notSmaller, artifacts: [],
                             warnings: validated.warnings + ["The cropped candidate was not smaller. Your original is retained."], attempts: attempt + 1)
            }
            try FileSafety.verifyUnchanged(inspection)
            try Task.checkCancellation()
            progress(.init(.saving))
            let output = try transaction.commit(candidate)
            return .init(operationID: .imageCrop, status: .succeeded,
                         artifacts: [.init(url: output, format: request.output.format, bytes: bytes, sourceIDs: [request.assets[0].id])],
                         warnings: validated.warnings, attempts: attempt + 1)
        }
        throw FileformError(.targetUnmet, "The complete cropped image could not fit under the byte limit within your quality and size settings.")
    }

    private static func resize(_ image: CGImage, maximumDimension: Int?, alpha: Bool) throws -> CGImage {
        guard let maximumDimension, max(image.width, image.height) > maximumDimension else { return image }
        try Task.checkCancellation()
        let scale = Double(maximumDimension) / Double(max(image.width, image.height))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: color, bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else {
            throw FileformError(.resourceLimit, "There is not enough memory to resize the crop.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw FileformError(.engineFailed, "The cropped image could not be resized.") }
        try Task.checkCancellation()
        return result
    }
}

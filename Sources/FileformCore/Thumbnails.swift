// SPDX-License-Identifier: Apache-2.0
import Foundation
import ImageIO
import FileformDomain

extension ConversionEngine {
    /// A bounded, orientation-correct display thumbnail. This is not a quality
    /// prediction: clients label it original/result according to the supplied file.
    public func thumbnail(for input: URL, maximumDimension: Int = 512) async throws -> Data {
        guard (1...1024).contains(maximumDimension) else { throw FileformError(.invalidRequest, "Thumbnail size must be between 1 and 1024 pixels.") }
        let inspection = try await inspect(input)
        guard inspection.family == .image, inspection.frameCount == 1, inspection.warnings.isEmpty else {
            throw FileformError(.unsupported, "A thumbnail is not available for this input.")
        }
        let rendered = try ImageBackend.render(inspection, options: .init(maxDimension: maximumDimension), format: .png)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw FileformError(.engineFailed, "Could not prepare a thumbnail.")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw FileformError(.engineFailed, "Could not finish the thumbnail.") }
        try FileSafety.verifyUnchanged(inspection)
        return data as Data
    }
}

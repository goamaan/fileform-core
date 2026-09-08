// SPDX-License-Identifier: Apache-2.0
import Foundation
import FileformDomain

enum ImageIntegrity {
    /// ImageIO can report a completed decode after repairing an incomplete JPEG.
    /// Require the original container's end record for formats with one. This is
    /// an additional integrity check, not a replacement for native decoding.
    static func validateEndRecord(_ input: URL, type: String, byteCount: Int64) throws {
        let expected: [UInt8]
        switch type {
        case "public.jpeg": expected = [0xff, 0xd9]
        case "public.png": expected = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]
        default: return
        }
        guard byteCount >= expected.count else { throw FileformError(.unsupported, "This image is incomplete.") }
        let handle = try FileHandle(forReadingFrom: input); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(byteCount - Int64(expected.count)))
        let actual = try handle.read(upToCount: expected.count)
        guard actual == Data(expected) else {
            throw FileformError(.unsupported, "This image is incomplete or contains extra embedded content. Export a complete still-image copy before converting it.")
        }
    }
}

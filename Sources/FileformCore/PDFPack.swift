// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import FileformDomain

public struct PDFPack: Sendable {
    public let directory: URL
    public let version: String
    let qpdf: URL
    public init(directory: URL) throws {
        struct Manifest: Decodable { let schemaVersion: Int; let id: String; let version: String; let executables: [String: String] }
        let url = directory.appendingPathComponent("manifest.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
              let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == 1, manifest.id == "app.fileform.pdf", !manifest.version.isEmpty else {
            throw FileformError(.engineUnavailable, "The PDF pack is missing or has an invalid manifest.")
        }
        let binary = directory.appendingPathComponent("bin/qpdf")
        guard FileManager.default.isExecutableFile(atPath: binary.path), let expected = manifest.executables["qpdf"],
              try Self.hash(binary) == expected else { throw FileformError(.engineUnavailable, "PDF pack integrity verification failed. Rebuild or reinstall the pack.") }
        self.directory = directory; version = manifest.version; qpdf = binary
    }
    static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import FileformDomain

public struct MediaPack: Sendable {
    public let directory: URL
    public let version: String
    let ffmpeg: URL
    let ffprobe: URL

    public init(directory: URL) throws {
        struct Manifest: Decodable {
            let schemaVersion: Int
            let id: String
            let version: String
            let networkProtocols: Bool
            let executables: [String: String]
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL), data.count <= 64 * 1024,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == 1, manifest.id == "app.fileform.media", !manifest.networkProtocols else {
            throw FileformError(.engineUnavailable, "The media pack is missing or has an invalid manifest.")
        }
        for name in ["ffmpeg", "ffprobe"] {
            let executable = directory.appendingPathComponent("bin/\(name)")
            guard FileManager.default.isExecutableFile(atPath: executable.path),
                  let expected = manifest.executables[name],
                  try Self.hash(executable) == expected else {
                throw FileformError(.engineUnavailable, "Media pack integrity verification failed. Rebuild or reinstall the pack.")
            }
        }
        self.directory = directory; self.version = manifest.version
        self.ffmpeg = directory.appendingPathComponent("bin/ffmpeg")
        self.ffprobe = directory.appendingPathComponent("bin/ffprobe")
    }

    private static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

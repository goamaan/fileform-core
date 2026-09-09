// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import FileformDomain

enum FileSafety {
    static func identity(_ url: URL) throws -> FileIdentity {
        guard url.isFileURL else { throw FileformError(.invalidRequest, "Choose a local file.") }
        var info = stat()
        guard url.resolvingSymlinksInPath().withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0 else {
            throw FileformError(.ioFailure, "The input file could not be read. Check that it exists and you have permission.")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw FileformError(.unsupported, "Choose a regular file, not a folder or device.")
        }
        guard info.st_size > 0 else { throw FileformError(.unsupported, "The input file is empty.") }
        return .init(device: info.st_dev, inode: info.st_ino, bytes: info.st_size,
                     modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    static func verifyUnchanged(_ inspection: Inspection) throws {
        guard try identity(inspection.input) == inspection.identity else {
            throw FileformError(.inputChanged, "This file changed after inspection. Inspect it again before converting.")
        }
    }
}

/// A private directory on the destination filesystem. Commit uses the kernel's
/// exclusive rename, so an intervening destination creation cannot be overwritten.
final class OutputTransaction {
    let directory: URL
    let destination: URL
    let collisionPolicy: CollisionPolicy
    private var cleaned = false
    private let sources: [(url: URL, identity: FileIdentity)]
    private let directoryOutput: Bool

    convenience init(destination: URL, input: URL, collisionPolicy: CollisionPolicy) throws {
        try self.init(destination: destination, inputs: [input], collisionPolicy: collisionPolicy, directoryOutput: false)
    }

    init(destination: URL, inputs: [URL], collisionPolicy: CollisionPolicy, directoryOutput: Bool) throws {
        guard !inputs.isEmpty else { throw FileformError(.invalidRequest, "Output needs source bindings.") }
        self.directoryOutput = directoryOutput
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty else {
            throw FileformError(.invalidRequest, "Choose a local output file.")
        }
        let final = destination.standardizedFileURL
        guard inputs.allSatisfy({ final.resolvingSymlinksInPath() != $0.standardizedFileURL.resolvingSymlinksInPath() }) else {
            throw FileformError(.invalidRequest, "The output must be different from the original.")
        }
        self.destination = final; self.collisionPolicy = collisionPolicy
        self.sources = try inputs.map { ($0, try FileSafety.identity($0)) }
        for source in sources { try Self.rejectAlias(final, sourceIdentity: source.identity) }
        let parent = final.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileformError(.ioFailure, "The output folder does not exist.")
        }
        if collisionPolicy == .fail && Self.exists(final) {
            throw FileformError(.destinationExists, "An item already exists at the output path. Choose another name.")
        }
        directory = parent.appendingPathComponent(".fileform-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw FileformError(.ioFailure, "Could not create temporary output. Check folder permissions and free space.") }
    }

    func candidate(_ attempt: Int, format: OutputFormat) -> URL {
        directory.appendingPathComponent("candidate-\(attempt).\(format.fileExtension)")
    }

    func commit(_ candidate: URL) throws -> URL {
        guard candidate.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw FileformError(.invalidRequest, "Cannot finalize a file not owned by this job.")
        }

        for suffix in 0..<1000 {
            try Task.checkCancellation()
            let renamed = directoryOutput ? "\(destination.lastPathComponent)-\(suffix)" : "\(destination.deletingPathExtension().lastPathComponent)-\(suffix).\(destination.pathExtension)"
            let target = suffix == 0 ? destination : destination.deletingLastPathComponent().appendingPathComponent(renamed)
            for source in sources {
                guard try FileSafety.identity(source.url) == source.identity else { throw FileformError(.inputChanged, "A source changed before publication.") }
                try Self.rejectAlias(target, sourceIdentity: source.identity)
                guard target.resolvingSymlinksInPath() != source.url.standardizedFileURL.resolvingSymlinksInPath() else { throw FileformError(.invalidRequest, "Destination aliases a source.") }
            }
            let result = candidate.withUnsafeFileSystemRepresentation { source in
                target.withUnsafeFileSystemRepresentation { target in renamex_np(source!, target!, UInt32(RENAME_EXCL)) }
            }
            if result == 0 { return target }
            let failure = errno
            if failure == EEXIST {
                if collisionPolicy == .rename { continue }
                throw FileformError(.destinationExists, "An item appeared at the output path. Your original and that item are unchanged.")
            }
            throw FileformError(.ioFailure, "Could not safely save the result (filesystem error \(failure)). Choose another folder.")
        }
        throw FileformError(.destinationExists, "Could not find an unused output name. Choose another folder or filename.")
    }

    func cleanup() {
        guard !cleaned else { return }
        cleaned = true
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { cleanup() }

    private static func rejectAlias(_ target: URL, sourceIdentity: FileIdentity) throws {
        if let existing = try? FileSafety.identity(target),
           existing.device == sourceIdentity.device, existing.inode == sourceIdentity.inode {
            throw FileformError(.invalidRequest, "The destination is an alias of the source file.")
        }
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { lstat($0!, &info) } == 0
    }
}

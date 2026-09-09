// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import CoreGraphics
import ImageIO
import PDFKit
import FileformDomain

/// Native parsing implementation used by the isolated worker. Calling this in a
/// UI process does not provide crash isolation. Descriptor ownership and sandbox
/// transfer are the launcher's responsibility; this bridge verifies file kinds
/// and source/output aliasing, and never commits a user destination.
public enum NativeWorkerOperations {
    public static let maximumInputBytes: Int64 = 512 * 1024 * 1024

    public static func execute(_ request: WorkerRequest) throws -> WorkerResponse {
        // Revalidate even callers arriving through a non-wire entrypoint.
        let validated = try JSONDecoder().decode(WorkerRequest.self, from: JSONEncoder().encode(request))
        if case .handshake = validated.operation {
            return try WorkerResponse(id: request.id, payload: .handshake(protocolVersion: WorkerProtocol.version))
        }
        do {
            let payload = try perform(validated.operation)
            return try WorkerResponse(id: request.id, payload: payload)
        } catch {
            return try WorkerResponse(id: request.id, payload: .failure(failureCode(error)))
        }
    }

    private static func perform(_ operation: WorkerOperation) throws -> WorkerResponsePayload {
        let asset: WorkerAssetHandle
        switch operation {
        case .inspect(let value), .pdfFingerprint(let value), .preview(let value, _, _, _): asset = value
        case .handshake: throw WorkerProtocolError.invalidRequest
        }
        let before = try sourceIdentity(asset.descriptor)
        if case .preview(_, let descriptor, _, _) = operation { try validateOutput(descriptor, source: before) }
        let scratchRoot = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let directory = scratchRoot.appendingPathComponent("fileform-worker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input")
        try copySource(asset.descriptor, identity: before, to: input)
        let inspection: Inspection
        if DocumentBackend.recognizesPDF(input) { inspection = try DocumentBackend.inspect(input, identity: before) }
        else if ImageBackend.canRead(input) { inspection = try ImageBackend.inspect(input, identity: before) }
        else { throw FileformError(.unsupported, "Unsupported native input.") }
        guard try sourceIdentity(asset.descriptor) == before else { throw FileformError(.inputChanged, "Source changed.") }
        switch operation {
        case .pdfFingerprint:
            return .pdfFingerprint(try PDFStructuralFingerprint.compute(input))
        case .inspect:
            return .inspection(try WorkerInspectionResult(assetID: asset.assetID, inspection: inspection))
        case .preview(_, let descriptor, let dimension, let pageIndex):
            let image: CGImage
            if inspection.family == .pdf {
                let document = try DocumentBackend.document(input)
                let index = pageIndex ?? 0
                guard let page = document.page(at: index) else { throw FileformError(.invalidRequest, "Page outside document.") }
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                    throw FileformError(.unsupported, "Invalid page dimensions.")
                }
                guard let pageRef = page.pageRef else { throw FileformError(.unsupported, "Invalid PDF page.") }
                let rotation = ((page.rotation % 360) + 360) % 360
                let sideways = rotation == 90 || rotation == 270
                let orientedWidth = sideways ? bounds.height : bounds.width
                let orientedHeight = sideways ? bounds.width : bounds.height
                let scale = CGFloat(dimension) / max(orientedWidth, orientedHeight)
                let width = max(1, min(dimension, Int(ceil(orientedWidth * scale))))
                let height = max(1, min(dimension, Int(ceil(orientedHeight * scale))))
                guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw FileformError(.resourceLimit, "Preview allocation failed.")
                }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.concatenate(pageRef.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                               rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(pageRef)
                guard let rendered = context.makeImage() else { throw FileformError(.engineFailed, "Preview failed.") }
                image = rendered
            } else {
                guard pageIndex == nil, inspection.frameCount == 1, inspection.warnings.isEmpty else {
                    throw FileformError(.unsupported, "Unsupported image preview.")
                }
                image = try ImageBackend.render(inspection, options: .init(maxDimension: dimension), format: .png)
            }
            let png = directory.appendingPathComponent("preview.png")
            try ImageBackend.encode(image, format: .png, quality: 1, destination: png)
            let bytes = try ImageBackend.verify(png, format: .png, rendered: image, preserveAlpha: inspection.hasAlpha == true)
            guard bytes <= maximumInputBytes else { throw FileformError(.resourceLimit, "Preview too large.") }
            guard try sourceIdentity(asset.descriptor) == before else { throw FileformError(.inputChanged, "Source changed.") }
            try validateOutput(descriptor, source: before)
            try writePreview(png, to: descriptor, expectedBytes: bytes)
            guard try sourceIdentity(asset.descriptor) == before else {
                _ = ftruncate(descriptor, 0)
                throw FileformError(.inputChanged, "Source changed.")
            }
            return .preview(.init(bytes: bytes, width: image.width, height: image.height))
        case .handshake: throw WorkerProtocolError.invalidRequest
        }
    }

    private static func sourceIdentity(_ descriptor: Int32) throws -> FileIdentity {
        var info = stat()
        let flags = fcntl(descriptor, F_GETFL)
        guard descriptor >= 3, flags >= 0, flags & O_ACCMODE != O_WRONLY,
              fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw FileformError(.ioFailure, "Source descriptor is not a readable regular file.")
        }
        guard info.st_size > 0, info.st_size <= maximumInputBytes else { throw FileformError(.resourceLimit, "Input size limit exceeded.") }
        return .init(device: info.st_dev, inode: info.st_ino, bytes: info.st_size,
                     modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    private static func validateOutput(_ descriptor: Int32, source: FileIdentity) throws {
        var info = stat()
        let flags = fcntl(descriptor, F_GETFL)
        guard descriptor >= 3, flags >= 0, flags & O_ACCMODE != O_RDONLY, flags & O_APPEND == 0,
              fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              !(info.st_dev == source.device && info.st_ino == source.inode), info.st_nlink == 1,
              info.st_size == 0 else { throw FileformError(.invalidRequest, "Preview needs an empty, distinct writable scratch file.") }
    }

    private static func copySource(_ descriptor: Int32, identity: FileIdentity, to destination: URL) throws {
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw FileformError(.ioFailure, "Could not create worker scratch file.") }
        defer { close(output) }
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < identity.bytes {
            try Task.checkCancellation()
            let count = pread(descriptor, &buffer, min(buffer.count, Int(identity.bytes - offset)), off_t(offset))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw FileformError(.inputChanged, "Could not read complete source.") }
            try buffer.withUnsafeBytes { try writeAll(output, bytes: UnsafeRawBufferPointer(rebasing: $0.prefix(count)), at: offset) }
            offset += Int64(count)
        }
        guard try sourceIdentity(descriptor) == identity else { throw FileformError(.inputChanged, "Source changed while copying.") }
    }

    private static func writePreview(_ input: URL, to descriptor: Int32, expectedBytes: Int64) throws {
        let source = open(input.path, O_RDONLY | O_NOFOLLOW)
        guard source >= 0 else { throw FileformError(.ioFailure, "Could not read preview.") }
        defer { close(source) }
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        do {
            while offset < expectedBytes {
                try Task.checkCancellation()
                let count = pread(source, &buffer, min(buffer.count, Int(expectedBytes - offset)), off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FileformError(.ioFailure, "Incomplete preview.") }
                try buffer.withUnsafeBytes { try writeAll(descriptor, bytes: UnsafeRawBufferPointer(rebasing: $0.prefix(count)), at: offset) }
                offset += Int64(count)
            }
            guard fsync(descriptor) == 0 else { throw FileformError(.ioFailure, "Could not flush preview.") }
        } catch { _ = ftruncate(descriptor, 0); throw error }
    }

    private static func writeAll(_ descriptor: Int32, bytes: UnsafeRawBufferPointer, at offset: Int64) throws {
        var written = 0
        while written < bytes.count {
            let count = pwrite(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written, off_t(offset + Int64(written)))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw FileformError(.ioFailure, "Worker scratch write failed.") }
            written += count
        }
    }

    private static func failureCode(_ error: Error) -> WorkerFailureCode {
        if error is CancellationError { return .cancelled }
        guard let error = error as? FileformError else { return .internalFailure }
        switch error.code {
        case .unsupported, .engineUnavailable: return .unsupportedInput
        case .resourceLimit: return .resourceLimit
        case .ioFailure: return .permissionDenied
        case .cancelled: return .cancelled
        case .invalidRequest, .inputChanged, .verificationFailed: return .invalidInput
        default: return .internalFailure
        }
    }
}

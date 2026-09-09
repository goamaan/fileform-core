// SPDX-License-Identifier: Apache-2.0
import Foundation
import AppKit
import PDFKit
import CoreGraphics
import Darwin
import FileformDomain

/// Everyday PDF composition. This backend does not itself provide worker isolation.
/// Sources are never edited; publication is an exclusive filesystem rename.
enum PDFCompositionBackend {
    static func plan(request: TransformationRequest, inspections: [InspectedAsset]) throws -> TransformationPlan {
        try request.validate()
        let groups = try pageGroups(request.operation)
        guard request.fidelity == .allowDeclaredLosses else {
            throw FileformError(.unsupported, "PDF assembly cannot guarantee lossless preservation of document metadata, forms, bookmarks or digital signatures.")
        }
        guard inspections.count == request.assets.count, inspections.map(\.id) == request.assets.map(\.id),
              inspections.count <= 128, groups.flatMap({ $0 }).count <= 1000 else {
            throw FileformError(.resourceLimit, "PDF assembly supports up to 128 sources and 1,000 output pages with matching source bindings.")
        }
        var total: Int64 = 0
        var fresh: [InspectedAsset] = []
        for (asset, supplied) in zip(request.assets, inspections) {
            try Task.checkCancellation()
            guard supplied.inspection.input.standardizedFileURL == asset.url.standardizedFileURL else {
                throw FileformError(.invalidRequest, "A PDF source binding does not match the plan.")
            }
            let identity = try FileSafety.identity(asset.url)
            guard identity == supplied.inspection.identity else { throw FileformError(.inputChanged, "A PDF source changed. Inspect it again.") }
            guard identity.bytes <= 512 * 1024 * 1024 - total else { throw FileformError(.resourceLimit, "Combined PDF sources exceed the 512 MiB input limit.") }
            total += identity.bytes
            let info: Inspection
            if DocumentBackend.recognizesPDF(asset.url) { info = try DocumentBackend.inspect(asset.url, identity: identity) }
            else if ImageBackend.canRead(asset.url) {
                info = try ImageBackend.inspect(asset.url, identity: identity)
                guard info.frameCount == 1, info.warnings.isEmpty else {
                    throw FileformError(.unsupported, "PDF assembly accepts SDR still images only.")
                }
            } else { throw FileformError(.unsupported, "Combine PDF documents and supported still images.") }
            try FileSafety.verifyUnchanged(info)
            fresh.append(.init(id: asset.id, inspection: info))
        }
        let byID = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0.inspection) })
        for page in groups.flatMap({ $0 }) {
            guard let info = byID[page.sourceID], page.pageIndex < (info.family == .pdf ? info.pageCount ?? 0 : 1) else {
                throw FileformError(.invalidRequest, "A selected page is outside its source document.")
            }
        }
        for asset in fresh where asset.inspection.family == .pdf {
            let document = try DocumentBackend.document(asset.inspection.input)
            for reference in groups.flatMap({ $0 }) where reference.sourceID == asset.id {
                guard let page = document.page(at: reference.pageIndex) else {
                    throw FileformError(.invalidRequest, "A selected PDF page is missing.")
                }
                for box in [PDFDisplayBox.mediaBox, .cropBox] {
                    let bounds = page.bounds(for: box)
                    guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
                          bounds.width > 0, bounds.height > 0, bounds.width <= 1_000_000, bounds.height <= 1_000_000,
                          page.rotation % 90 == 0 else {
                        throw FileformError(.unsupported, "A selected PDF page has unsupported dimensions or rotation.")
                    }
                }
            }
            try FileSafety.verifyUnchanged(asset.inspection)
        }
        try FileSafety.rejectSourceAliases(destination: request.output.destination, inputs: fresh.map(\.inspection))
        var warnings = ["A new PDF is created. Document-level bookmarks, metadata and form behavior are not guaranteed to carry over; existing digital signatures do not certify the new document.",
                        "PDF page sizes, visible content and rotation are retained. Originals remain unchanged."]
        if fresh.contains(where: { $0.inspection.family == .image }) {
            warnings.append("Each image becomes one page at one PDF point per oriented pixel. Images use sRGB and omit descriptive metadata; transparent areas appear against the PDF page background.")
        }
        return .init(request: request, inputs: fresh, warnings: warnings)
    }

    static func execute(plan supplied: TransformationPlan, progress: @Sendable (ProgressEvent) -> Void) throws -> TransformationResult {
        guard supplied.schemaVersion == 1 else { throw FileformError(.invalidRequest, "Unsupported PDF plan version.") }
        let plan = try self.plan(request: supplied.request, inspections: supplied.inputs)
        let groups = try pageGroups(plan.request.operation)
        let transaction = try PDFAssemblyTransaction(destination: plan.request.output.destination,
            directoryOutput: plan.request.output.cardinality == .directory,
            collision: plan.request.collisionPolicy, sources: plan.inputs.map(\.inspection))
        defer { transaction.cleanup() }
        progress(.init(.preparing))
        var documents: [String: PDFDocument] = [:]
        var imagePages: [String: PDFPage] = [:]
        for asset in plan.inputs {
            try Task.checkCancellation()
            if asset.inspection.family == .pdf { documents[asset.id] = try DocumentBackend.document(asset.inspection.input) }
            else {
                let image = try ImageBackend.render(asset.inspection, options: .init(), format: .png)
                let native = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                guard let page = PDFPage(image: native) else { throw FileformError(.engineFailed, "Could not prepare an image page.") }
                page.setBounds(CGRect(x: 0, y: 0, width: image.width, height: image.height), for: .mediaBox)
                imagePages[asset.id] = page
            }
        }
        var staged: [(name: String, bytes: Int64, sourceIDs: [String])] = []
        for (index, pages) in groups.enumerated() {
            try Task.checkCancellation()
            progress(.init(.encoding))
            let document = PDFDocument()
            for reference in pages {
                try Task.checkCancellation()
                guard let original = documents[reference.sourceID]?.page(at: reference.pageIndex) ?? imagePages[reference.sourceID],
                      let copied = original.copy() as? PDFPage else { throw FileformError(.engineFailed, "Could not copy a selected page.") }
                copied.rotation = normalizedRotation(normalizedRotation(original.rotation) + reference.clockwiseRotation)
                document.insert(copied, at: document.pageCount)
            }
            let name = plan.request.output.cardinality == .directory ? String(format: "part-%04d.pdf", index + 1) : "result.pdf"
            let candidate = transaction.candidate(name)
            guard document.write(to: candidate) else { throw FileformError(.engineFailed, "Could not write the assembled PDF.") }
            try Task.checkCancellation()
            progress(.init(.verifying))
            let bytes = try verify(candidate, expected: document)
            var ids: [String] = []
            for page in pages where !ids.contains(page.sourceID) { ids.append(page.sourceID) }
            staged.append((name, bytes, ids))
        }
        progress(.init(.saving))
        try Task.checkCancellation()
        let committed = try transaction.commit()
        let artifacts = staged.map { item in
            CommittedArtifact(url: plan.request.output.cardinality == .directory ? committed.appendingPathComponent(item.name) : committed,
                              format: .pdf, bytes: item.bytes, sourceIDs: item.sourceIDs)
        }
        return .init(operationID: plan.request.operation.id, status: .succeeded, artifacts: artifacts, warnings: plan.warnings, attempts: 1)
    }

    private static func pageGroups(_ operation: TransformationOperation) throws -> [[PageReference]] {
        switch operation {
        case .pdfComposition(let pages): return [pages]
        case .pdfSplit(let groups): return groups
        default: throw FileformError(.unsupported, "This is not a PDF assembly operation.")
        }
    }
    private static func normalizedRotation(_ value: Int) -> Int { ((value % 360) + 360) % 360 }
    private static func verify(_ url: URL, expected: PDFDocument) throws -> Int64 {
        let actual = try DocumentBackend.document(url)
        guard actual.pageCount == expected.pageCount else { throw FileformError(.verificationFailed, "The PDF page count changed during saving.") }
        for index in 0..<expected.pageCount {
            try Task.checkCancellation()
            guard let before = expected.page(at: index), let after = actual.page(at: index),
                  normalizedRotation(before.rotation) == normalizedRotation(after.rotation),
                  before.bounds(for: .mediaBox) == after.bounds(for: .mediaBox),
                  before.bounds(for: .cropBox) == after.bounds(for: .cropBox),
                  before.string == after.string,
                  let page = after.pageRef else { throw FileformError(.verificationFailed, "Saved PDF pages do not match their planned content, size or orientation.") }
            // Force a bounded decode, instead of accepting parseable page objects only.
            guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw FileformError(.resourceLimit, "Could not verify the PDF preview.")
            }
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: 64, height: 64), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard context.makeImage() != nil else { throw FileformError(.verificationFailed, "The saved page cannot render.") }
        }
        return try FileSafety.identity(url).bytes
    }
}

private final class PDFAssemblyTransaction {
    let root: URL
    private let payload: URL
    private let destination: URL
    private let directoryOutput: Bool
    private let collision: CollisionPolicy
    private let sources: [Inspection]
    init(destination: URL, directoryOutput: Bool, collision: CollisionPolicy, sources: [Inspection]) throws {
        self.destination = destination.standardizedFileURL; self.directoryOutput = directoryOutput
        self.collision = collision; self.sources = sources
        try FileSafety.rejectSourceAliases(destination: destination, inputs: sources)
        root = destination.deletingLastPathComponent().appendingPathComponent(".fileform-pdf-\(UUID().uuidString)", isDirectory: true)
        payload = root.appendingPathComponent(directoryOutput ? "parts" : "result.pdf", isDirectory: directoryOutput)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            if directoryOutput { try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func candidate(_ name: String) -> URL { directoryOutput ? payload.appendingPathComponent(name) : payload }
    func commit() throws -> URL {
        for index in 0..<1000 {
            try Task.checkCancellation()
            for source in sources { try FileSafety.verifyUnchanged(source) }
            let target: URL
            if index == 0 { target = destination }
            else if directoryOutput { target = destination.deletingLastPathComponent().appendingPathComponent("\(destination.lastPathComponent)-\(index)", isDirectory: true) }
            else { target = destination.deletingLastPathComponent().appendingPathComponent("\(destination.deletingPathExtension().lastPathComponent)-\(index).pdf") }
            try FileSafety.rejectSourceAliases(destination: target, inputs: sources)
            let result = payload.withUnsafeFileSystemRepresentation { input in
                target.withUnsafeFileSystemRepresentation { output in renamex_np(input!, output!, UInt32(RENAME_EXCL)) }
            }
            if result == 0 { return target }
            let error = errno
            if error == EEXIST {
                if collision == .rename { continue }
                throw FileformError(.destinationExists, "The output already exists. Choose a new name or keep both.")
            }
            throw FileformError(.ioFailure, "Could not safely publish the complete PDF result.")
        }
        throw FileformError(.destinationExists, "No unused PDF output name was found.")
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

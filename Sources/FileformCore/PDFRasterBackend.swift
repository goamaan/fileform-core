// SPDX-License-Identifier: Apache-2.0
import Foundation
import ImageIO
import FileformDomain

/// Full-resolution page export. Every untrusted PDF render runs in the native
/// worker; the coordinator verifies and publishes one complete output directory.
struct PDFRasterBackend {
    let worker: NativeWorkerClient

    func plan(_ request: TransformationRequest, previous: [InspectedAsset]? = nil) async throws -> TransformationPlan {
        try request.validate()
        guard case .pdfRasterize(let pages, let dpi, let quality) = request.operation else { throw FileformError(.invalidRequest, "Expected page export.") }
        guard request.fidelity == .allowDeclaredLosses else { throw FileformError(.unsupported, "Rasterizing pages cannot preserve editable text, vectors, forms or signatures.") }
        if let previous {
            guard previous.map(\.id) == request.assets.map(\.id), zip(previous, request.assets).allSatisfy({ $0.inspection.input.standardizedFileURL == $1.url.standardizedFileURL }) else { throw FileformError(.invalidRequest, "Page export source bindings changed.") }
            for source in previous { try FileSafety.verifyUnchanged(source.inspection) }
        }
        var total: Int64 = 0
        for asset in request.assets {
            let bytes = try FileSafety.identity(asset.url).bytes
            guard bytes <= 512 * 1024 * 1024 - total else { throw FileformError(.resourceLimit, "Page export accepts at most 512 MiB of source files.") }
            total += bytes
        }
        var inputs: [InspectedAsset] = []
        for asset in request.assets {
            try Task.checkCancellation()
            let info = try await worker.inspect(asset.url)
            guard info.family == .pdf || (info.family == .image && info.frameCount == 1 && info.warnings.isEmpty) else { throw FileformError(.unsupported, "Export PDF pages and SDR still images only.") }
            inputs.append(.init(id: asset.id, inspection: info))
        }
        let byID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.inspection) })
        var checked: [PageReference] = []
        for page in pages {
            guard let source = byID[page.sourceID], page.pageIndex < (source.family == .pdf ? source.pageCount ?? 0 : 1) else { throw FileformError(.invalidRequest, "A selected page is outside its source.") }
            if !checked.contains(page) {
                _ = try await worker.rasterPage(source.input, pageIndex: page.pageIndex, clockwiseRotation: page.clockwiseRotation, dpi: dpi, format: request.output.format, quality: quality)
                checked.append(page)
            }
        }
        for source in inputs { try FileSafety.verifyUnchanged(source.inspection) }
        if let previous {
            guard zip(previous, inputs).allSatisfy({ $0.inspection.identity == $1.inspection.identity }) else { throw FileformError(.inputChanged, "A source changed while preparing page export.") }
        }
        try FileSafety.rejectSourceAliases(destination: request.output.destination, inputs: inputs.map(\.inspection))
        return .init(request: request, inputs: inputs, warnings: [
            "Each selected page becomes an sRGB image at the requested DPI, on a white background. PDF crop boxes and displayed rotation are applied; visible annotation and filled-form appearances become pixels. Hidden annotations are omitted; selection order and duplicates are retained.",
            "Rasterization replaces searchable text and vector content with pixels. Editable forms, links, bookmarks, document metadata and digital signatures do not carry over; originals remain unchanged.",
            "Still images use one PDF point per oriented pixel before DPI scaling. Exports exceeding 64 million pixels or a 16384-pixel edge are rejected without reducing resolution.",
            request.output.format == .png ? "PNG encodes the rendered pixels losslessly; rasterization itself is not a lossless PDF conversion." : "JPEG adds lossy image compression at the selected quality."
        ])
    }

    func execute(_ supplied: TransformationPlan, progress: @Sendable (ProgressEvent) -> Void) async throws -> TransformationResult {
        guard supplied.schemaVersion == 1 else { throw FileformError(.invalidRequest, "Unsupported page export plan.") }
        let plan = try await plan(supplied.request, previous: supplied.inputs)
        guard case .pdfRasterize(let pages, let dpi, let quality) = plan.request.operation else { throw FileformError(.invalidRequest, "Expected page export.") }
        let format = plan.request.output.format
        let transaction = try OutputTransaction(destination: plan.request.output.destination, inputs: plan.inputs.map { $0.inspection.input }, collisionPolicy: plan.request.collisionPolicy, directoryOutput: true)
        defer { transaction.cleanup() }
        let payload = transaction.directory.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let byID = Dictionary(uniqueKeysWithValues: plan.inputs.map { ($0.id, $0.inspection) })
        var outputs: [(name: String, bytes: Int64, page: PageReference)] = []
        progress(.init(.preparing))
        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            let name = String(format: "%03d", index + 1) + "." + format.fileExtension
            let candidate = payload.appendingPathComponent(name)
            progress(.init(.encoding))
            let metadata = try await worker.rasterPage(byID[page.sourceID]!.input, destination: candidate, pageIndex: page.pageIndex, clockwiseRotation: page.clockwiseRotation, dpi: dpi, format: format, quality: quality)
            progress(.init(.verifying))
            try Self.verify(candidate, expected: metadata, dpi: dpi)
            outputs.append((name, metadata.bytes!, page))
        }
        progress(.init(.saving))
        for source in plan.inputs { try FileSafety.verifyUnchanged(source.inspection) }
        let committed = try transaction.commit(payload)
        return .init(operationID: .pdfRasterize, status: .succeeded,
            artifacts: outputs.map { .init(url: committed.appendingPathComponent($0.name), format: format, bytes: $0.bytes, sourceIDs: [$0.page.sourceID], sourcePages: [$0.page]) },
            warnings: plan.warnings, attempts: 1)
    }

    private static func verify(_ url: URL, expected: WorkerRasterArtifact, dpi: Int) throws {
        let bytes = try FileSafety.identity(url).bytes
        guard bytes == expected.bytes, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == expected.format.imageType,
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == expected.width, image.height == expected.height else { throw FileformError(.verificationFailed, "Page export failed image completeness or dimension checks.") }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let horizontal = properties[kCGImagePropertyDPIWidth] as? Double, let vertical = properties[kCGImagePropertyDPIHeight] as? Double,
              abs(horizontal - Double(dpi)) < 0.03, abs(vertical - Double(dpi)) < 0.03 else { throw FileformError(.verificationFailed, "Page resolution metadata does not match the requested DPI.") }
        try ImageIntegrity.validateEndRecord(url, type: expected.format.imageType!, byteCount: bytes)
    }
}

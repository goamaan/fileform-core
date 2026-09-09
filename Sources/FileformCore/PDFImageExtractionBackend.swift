// SPDX-License-Identifier: Apache-2.0
import Foundation
import FileformDomain

struct PDFImageExtractionBackend {
    let pack: PDFPack
    let worker: NativeWorkerClient
    private static let limit: Int64 = 512 * 1024 * 1024
    private static let warnings = [
        "Images are discovered through selected PDF pages’ resources and nested Forms, including inherited and indirect resources. Resource references are not paint occurrences: unused resources may be included. Inline images, annotation appearances and patterns are not enumerated.",
        "Each source/object/generation is exported once at intrinsic dimensions. Eligible JPEG bytes are preserved; supported 8-bit DeviceRGB/DeviceGray samples become PNG, preserving supported soft-mask alpha and hidden RGB. Page rotation, clipping and placement are irrelevant to intrinsic images.",
        "Unsupported image candidates are listed explicitly. No PDF page is rasterized as an extraction fallback. Originals remain unchanged."
    ]
    private func discover(_ request: TransformationRequest, previous: [InspectedAsset]? = nil) async throws -> (TransformationPlan, [PDFImageGraph.Image]) {
        try request.validate()
        guard case .pdfExtractImages(let selected) = request.operation else { throw FileformError(.invalidRequest, "Expected embedded image extraction.") }
        if let previous {
            guard previous.map(\.id) == request.assets.map(\.id), zip(previous, request.assets).allSatisfy({ $0.inspection.input.standardizedFileURL == $1.url.standardizedFileURL }) else { throw FileformError(.invalidRequest, "Extraction source bindings changed.") }
            for source in previous { try FileSafety.verifyUnchanged(source.inspection) }
        }
        var inputs: [InspectedAsset] = [], images: [PDFImageGraph.Image] = [], sourceBytes: Int64 = 0, sampleBytes: Int64 = 0, provenanceBytes = 0
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("fileform-pdf-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        for (index, asset) in request.assets.enumerated() {
            try Task.checkCancellation()
            let bytes = try FileSafety.identity(asset.url).bytes
            guard bytes <= Self.limit - sourceBytes else { throw FileformError(.resourceLimit, "Image extraction accepts at most 512 MiB of PDF sources.") }
            sourceBytes += bytes
            let info = try await worker.inspect(asset.url)
            guard info.family == .pdf else { throw FileformError(.unsupported, "Embedded image extraction accepts PDF sources only.") }
            guard !inputs.contains(where: { $0.inspection.identity.device == info.identity.device && $0.inspection.identity.inode == info.identity.inode }) else {
                throw FileformError(.invalidRequest, "Bind each PDF source only once; select repeated page references instead of duplicate files or aliases.")
            }
            inputs.append(.init(id: asset.id, inspection: info))
            let json = scratch.appendingPathComponent("objects-\(index).json")
            let output = try await ProcessRunner.run(executable: pack.qpdf,
                arguments: [asset.url.path, "--json", "--json-key=qpdf", "--json-key=pages", "--json-key=encrypt"], timeout: 60,
                stdoutFile: json, maximumStdoutBytes: 32 * 1024 * 1024)
            guard output.status == 0 else { throw FileformError(.unsupported, "The PDF object inventory could not be read cleanly. Encrypted or damaged PDFs are unsupported.") }
            let graph = try PDFImageGraph(data: Data(contentsOf: json))
            var pages: [PageReference] = []
            for page in selected where page.sourceID == asset.id && !pages.contains(page) { pages.append(page) }
            let discovered = try graph.images(sourceID: asset.id, pages: pages)
            guard discovered.count <= 1000 - images.count else { throw FileformError(.resourceLimit, "Extract at most 1000 unique image objects per job.") }
            for image in discovered where image.candidate.skipReason == nil {
                let bytes = Int64(image.candidate.width!) * Int64(image.candidate.height!) * 4
                guard bytes <= Self.limit - sampleBytes else { throw FileformError(.resourceLimit, "The cumulative decoded image budget exceeds 512 MiB.") }
                sampleBytes += bytes
            }
            provenanceBytes += discovered.reduce(0) { $0 + $1.candidate.resourcePaths.reduce(0) { $0 + $1.utf8.count } }
            guard provenanceBytes <= 4 * 1024 * 1024 else { throw FileformError(.resourceLimit, "The combined image provenance exceeds 4 MiB.") }
            images += discovered
            try FileSafety.verifyUnchanged(info)
        }
        for source in inputs { try FileSafety.verifyUnchanged(source.inspection) }
        if let previous, !zip(previous, inputs).allSatisfy({ $0.inspection.identity == $1.inspection.identity }) { throw FileformError(.inputChanged, "A source changed during extraction planning.") }
        try FileSafety.rejectSourceAliases(destination: request.output.destination, inputs: inputs.map(\.inspection))
        let details = PDFImageExtractionDetails(candidates: images.map(\.candidate))
        var warnings = Self.warnings
        if details.skippedCount > 0 { warnings.append("\(details.skippedCount) of \(details.discoveredCount) unique image objects are unsupported and will be skipped; inspect candidate reasons.") }
        if details.discoveredCount == 0 { warnings.append("No embedded image objects were found in the selected page resources.") }
        else if details.supportedCount == 0 { warnings.append("None of the discovered image objects can be exported with the supported encoding policy.") }
        return (.init(request: request, inputs: inputs, warnings: warnings, pdfImageExtraction: details), images)
    }
    func plan(_ request: TransformationRequest) async throws -> TransformationPlan { try await discover(request).0 }
    func execute(_ supplied: TransformationPlan, progress: @Sendable (ProgressEvent) -> Void) async throws -> TransformationResult {
        guard supplied.schemaVersion == 1 else { throw FileformError(.invalidRequest, "Unsupported extraction plan version.") }
        progress(.init(.preparing))
        let (plan, images) = try await discover(supplied.request, previous: supplied.inputs)
        guard plan.pdfImageExtraction!.supportedCount > 0 else { throw FileformError(.unsupported,
            images.isEmpty ? "No embedded images were found in the selected PDF page resources." : "All discovered images are unsupported; review their skip reasons. No folder was created.") }
        let transaction = try OutputTransaction(destination: plan.request.output.destination, inputs: plan.inputs.map { $0.inspection.input }, collisionPolicy: plan.request.collisionPolicy, directoryOutput: true)
        defer { transaction.cleanup() }
        let payload = transaction.directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let byID = Dictionary(uniqueKeysWithValues: plan.inputs.map { ($0.id, $0.inspection) })
        var candidates: [PDFEmbeddedImageCandidate] = [], cumulativeBytes: Int64 = 0
        for (index, image) in images.enumerated() {
            try Task.checkCancellation()
            var candidate = image.candidate
            guard candidate.skipReason == nil else { candidates.append(candidate); continue }
            let input = byID[candidate.sourceID]!.input, jpeg = candidate.encodingOutcome == .preservedEncodedBytes
            let source = transaction.directory.appendingPathComponent("stream-\(index)")
            let streamLimit = jpeg ? 256 * 1024 * 1024 : Int64(candidate.width! * candidate.height! * image.channels)
            progress(.init(.encoding, fraction: Double(index) / Double(images.count)))
            try await stream(input, reference: image.reference, raw: jpeg, destination: source, limit: streamLimit)
            if !jpeg, try FileSafety.identity(source).bytes != streamLimit { throw FileformError(.verificationFailed, "Decoded image stream is truncated or has unexpected samples.") }
            if let mask = image.softMask {
                let alpha = transaction.directory.appendingPathComponent("alpha-\(index)")
                let alphaCount = Int64(candidate.width! * candidate.height!)
                try await stream(input, reference: mask, raw: false, destination: alpha, limit: alphaCount)
                guard try FileSafety.identity(alpha).bytes == alphaCount else { throw FileformError(.verificationFailed, "Decoded soft mask has an unexpected sample count.") }
                let writer = try FileHandle(forWritingTo: source), reader = try FileHandle(forReadingFrom: alpha)
                do {
                    defer { try? writer.close(); try? reader.close() }
                    try writer.seekToEnd()
                    while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); try writer.write(contentsOf: data) }
                }
                try FileManager.default.removeItem(at: alpha)
            }
            let format: OutputFormat = jpeg ? .jpeg : .png
            let name = String(format: "%03d", index + 1) + "-object-\(candidate.objectNumber)-\(candidate.generation)." + format.fileExtension
            let destination = payload.appendingPathComponent(name)
            let artifact = try await worker.embeddedImage(source, destination: destination, width: candidate.width!, height: candidate.height!, channels: image.channels, hasAlpha: image.softMask != nil, encodedJPEG: jpeg)
            progress(.init(.verifying))
            let bytes = try FileSafety.identity(destination).bytes
            guard bytes == artifact.bytes, bytes <= Self.limit - cumulativeBytes else { throw FileformError(.resourceLimit, "Extracted output exceeds the 512 MiB cumulative limit.") }
            cumulativeBytes += bytes
            let digest = try PDFPack.hash(destination)
            if jpeg, try PDFPack.hash(source) != digest { throw FileformError(.verificationFailed, "Original JPEG bytes were not preserved.") }
            candidate.artifactName = name; candidate.byteCount = bytes; candidate.sha256 = digest
            candidates.append(candidate)
            try FileManager.default.removeItem(at: source)
        }
        for source in plan.inputs { try FileSafety.verifyUnchanged(source.inspection) }
        try Task.checkCancellation()
        progress(.init(.saving))
        let committed = try transaction.commit(payload)
        let artifacts: [CommittedArtifact] = candidates.compactMap { candidate in
            guard let name = candidate.artifactName, let bytes = candidate.byteCount else { return nil }
            return .init(url: committed.appendingPathComponent(name), format: candidate.encodingOutcome == .preservedEncodedBytes ? .jpeg : .png,
                bytes: bytes, sourceIDs: [candidate.sourceID], sourcePages: candidate.resourcePages, pdfEmbeddedImage: candidate)
        }
        return .init(operationID: .pdfExtractImages, status: .succeeded, artifacts: artifacts, warnings: plan.warnings, attempts: 1,
            pdfImageExtraction: .init(candidates: candidates))
    }
    private func stream(_ input: URL, reference: String, raw: Bool, destination: URL, limit: Int64) async throws {
        guard let (object, generation) = PDFImageGraph.reference(reference) else { throw FileformError(.verificationFailed, "Invalid image object reference.") }
        let result = try await ProcessRunner.run(executable: pack.qpdf,
            arguments: [input.path, "--show-object=\(object),\(generation)", raw ? "--raw-stream-data" : "--filtered-stream-data"],
            timeout: 60, stdoutFile: destination, maximumStdoutBytes: max(1, limit))
        guard result.status == 0 else { throw FileformError(.verificationFailed, "An image stream could not be decoded cleanly; no output folder was published.") }
    }
}

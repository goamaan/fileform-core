// SPDX-License-Identifier: Apache-2.0
import Foundation
import FileformDomain

/// Serializes heavy jobs away from client UI actors. Native codec calls are bounded
/// by input limits; cooperative cancellation is checked between encode/verify steps.
public actor ConversionEngine {
    private let mediaPackURL: URL?
    private let pdfPackURL: URL?
    private let workerExecutable: URL?
    private var loadedMedia: MediaBackend?
    let gate = JobGate() // Shared by operation-specific execution extensions.
    public init(mediaPack: URL? = nil, pdfPack: URL? = nil, workerExecutable: URL? = nil) {
        self.mediaPackURL = mediaPack; self.pdfPackURL = pdfPack; self.workerExecutable = workerExecutable
    }
    func pdfBackend() throws -> PDFOptimizationBackend {
        guard let pdfPackURL else { throw FileformError(.engineUnavailable, "Install the PDF engine pack to optimize this PDF.") }
        let worker = workerExecutable ?? ProcessInfo.processInfo.environment["FILEFORM_WORKER_PATH"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("fileform-worker")
        guard FileManager.default.isExecutableFile(atPath: worker.path) else { throw FileformError(.engineUnavailable, "Install the native worker alongside the PDF engine.") }
        return PDFOptimizationBackend(pack: try PDFPack(directory: pdfPackURL), worker: NativeWorkerClient(executable: worker, timeout: 120))
    }

    func mediaBackend() throws -> MediaBackend {
        if let loadedMedia { return loadedMedia }
        guard let mediaPackURL else { throw FileformError(.engineUnavailable, "Install the media engine pack to convert this recording.") }
        let media = MediaBackend(pack: try MediaPack(directory: mediaPackURL))
        loadedMedia = media
        return media
    }

    public func inspect(_ input: URL) async throws -> Inspection {
        try Task.checkCancellation()
        let input = input.standardizedFileURL
        let identity = try FileSafety.identity(input)
        if DocumentBackend.recognizesPDF(input) {
            let inspection = try DocumentBackend.inspect(input, identity: identity)
            try FileSafety.verifyUnchanged(inspection)
            return inspection
        }
        if ImageBackend.canRead(input) {
            let inspection = try ImageBackend.inspect(input, identity: identity)
            try FileSafety.verifyUnchanged(inspection)
            return inspection
        }
        if TableBackend.recognizes(input) {
            let inspection = try TableBackend.inspect(input, identity: identity)
            try FileSafety.verifyUnchanged(inspection)
            return inspection
        }
        if mediaPackURL != nil {
            let inspection = try await mediaBackend().inspect(input, identity: identity)
            try FileSafety.verifyUnchanged(inspection)
            return inspection
        }
        throw FileformError(.unsupported, "No supported transformation was found for this file. Images, PDFs and flat tables work locally; recordings need the media engine pack.")
    }

    public func capabilities(for inspection: Inspection? = nil) -> [Capability] {
        let media = try? mediaBackend()
        let mediaAvailable = media != nil
        switch inspection?.family {
        case .image: return ImageBackend.capabilities() + DocumentBackend.capabilities(for: inspection)
        case .media: return MediaBackend.capabilities(for: inspection, available: mediaAvailable, mp3Available: media?.pack.supportsMP3Encoding == true)
        case .pdf: return DocumentBackend.capabilities(for: inspection) + [PDFOptimizationBackend.capability(available: (try? pdfBackend()) != nil)]
        case .table: return TableBackend.capabilities(for: inspection)
        case .none: return ImageBackend.capabilities() + MediaBackend.capabilities(for: nil, available: mediaAvailable, mp3Available: media?.pack.supportsMP3Encoding == true) + DocumentBackend.capabilities(for: nil) + TableBackend.capabilities(for: nil) + [PDFOptimizationBackend.capability(available: (try? pdfBackend()) != nil)]
        default: return []
        }
    }

    public func capabilityInventory(for inspection: Inspection? = nil) -> CapabilityInventory {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let mediaVersion = try? mediaBackend().pack.version
        var routes = capabilities(for: inspection).map { capability in
            let families: [FileFamily]
            let verification: String
            switch capability.engine {
            case "imageio": families = [.image]; verification = "Reopen container, dimensions and alpha; check byte constraints."
            case "ffmpeg": families = [.media]; verification = "Decode all streams; verify codecs, dimensions and duration."
            case "qpdf": families = [.pdf]; verification = "All-page decoded content, text, five boxes, rotation and bounded rendered pixels; strict structural checks and byte constraints."
            case "tables": families = [.table]; verification = "Reparse and compare every record and cell."
            default: families = inspection.map { [$0.family] } ?? ([OutputFormat.pdf, .txt].contains(capability.format) ? [.image, .pdf] : [.pdf])
                verification = "Reopen page or text output; verify selected-page properties."
            }
            return OperationCapability(id: "file.convert:\(capability.engine):\(capability.format.rawValue)",
                inputFamilies: families, capability: capability,
                backendVersion: capability.engine == "ffmpeg" ? mediaVersion : (capability.engine == "qpdf" ? (try? pdfBackend().pack.version) : os), verification: verification)
        }
        if inspection == nil || inspection?.family == .image {
            for capability in ImageBackend.capabilities() {
                routes.append(.init(id: "image.crop:imageio:\(capability.format.rawValue)", inputFamilies: [.image], capability: capability,
                                    backendVersion: os, verification: "Oriented crop pixels, dimensions, alpha and exact byte constraints.", operationID: .imageCrop))
            }
        }
        if inspection == nil || inspection?.family == .media {
            for format in MediaBackend.formats where format != .mp3 && (inspection == nil ||
                ([OutputFormat.mp4, .mov].contains(format) ? inspection?.videoCodec != nil : inspection?.audioCodec != nil)) {
                let capability = Capability(format: format, goals: [.convert], engine: "ffmpeg", available: mediaVersion != nil,
                    limitation: "Exact frame/sample trim; eligible H.264/AAC MP4-family fast copy snaps outward. Constant-rate video, explicit audio selection, bounded packet inventory; MP3 unavailable.")
                routes.append(.init(id: "media.trim:ffmpeg:\(format.rawValue)", inputFamilies: [.media], capability: capability,
                    backendVersion: mediaVersion, verification: "Measured frame/sample boundaries, copied packet hashes, complete decode, stream and duration checks.", operationID: .mediaTrim))
            }
        }
        if inspection == nil || [.image, .pdf].contains(inspection!.family) {
            for (operation, cardinality) in [(OperationID.pdfComposition, OutputCardinality.file), (.pdfSplit, .directory)] {
                let capability = Capability(format: .pdf, goals: [.convert], engine: "pdf-composition", available: true,
                    limitation: "Up to 128 sources and 1000 output pages; document-level metadata, forms, outlines and signatures have declared losses.")
                routes.append(.init(id: operation.rawValue + ":pdfkit:pdf", inputFamilies: [.image, .pdf], capability: capability,
                    backendVersion: os, verification: "Reopen every PDF; compare page count, order, text, boxes and rotation before atomic publication.",
                    operationID: operation, cardinality: cardinality))
            }
        }
        if inspection == nil {
            for format in DirectFetchBackend.formats {
                let capability = Capability(format: format, goals: [.convert], engine: "direct-http", available: mediaVersion != nil,
                    limitation: "Explicit direct HTTP(S) media only; original bytes kept, no web-page extraction. Byte/redirect/time limits and complete media decode before saving.")
                routes.append(.init(id: "link.fetch:direct-http:\(format.rawValue)", inputFamilies: [], capability: capability,
                    backendVersion: mediaVersion, verification: "Response validators, retained-byte ceiling, forced media container, full decode and SHA-256 before exclusive publication.",
                    operationID: .fetch, localProcessing: false))
            }
        }
        return .init(engineVersion: "0.1.0-dev", platformVersion: os, inputFamily: inspection?.family, routes: routes)
    }

    public func plan(_ request: ConversionRequest) async throws -> ConversionPlan {
        try validateOptions(request)
        let inspection: Inspection
        if request.format == .pdf, request.goal != .convert, DocumentBackend.recognizesPDF(request.input) { inspection = try await pdfBackend().worker.inspect(request.input) }
        else { inspection = try await inspect(request.input) }
        try FileSafety.rejectSourceAliases(destination: request.destination, inputs: [inspection])
        if request.options.pageNumber != nil && inspection.family != .pdf {
            throw FileformError(.invalidRequest, "Page selection is only available for PDF inputs.")
        }
        guard let capability = capabilities(for: inspection).first(where: { $0.format == request.format && $0.goals.contains(request.goal) }),
              capability.available, capability.goals.contains(request.goal) else {
            throw FileformError(.unsupported, "This input/output operation is not available.")
        }
        if capability.engine == "qpdf" {
            try await pdfBackend().validate(inspection, request: request)
            return .init(request: request, inspection: inspection, engine: "qpdf", warnings: PDFOptimizationBackend.warnings)
        }
        if capability.engine == "documents" {
            try DocumentBackend.validate(inspection, request: request)
            return .init(request: request, inspection: inspection, engine: capability.engine,
                         warnings: DocumentBackend.warnings(inspection, request: request))
        }
        if inspection.family == .table {
            guard request.options.maxDimension == nil, request.options.background == nil else {
                throw FileformError(.invalidRequest, "Image options do not apply to table conversions.")
            }
            if request.format == .json && inspection.tableRows == 0 {
                throw FileformError(.unsupported, "An empty JSON array cannot retain column names. Choose TSV/CSV or add a data row.")
            }
            let warnings = request.format == .json
                ? ["Every CSV/TSV cell is preserved as a JSON string. Numeric types and formulas are not inferred."]
                : ["CSV and TSV store text cells. JSON null becomes an empty cell, and JSON value types are not retained.",
                   "Spreadsheet apps may interpret cells beginning with =, +, - or @ as formulas. Review the exported values before opening them in a spreadsheet."]
            return .init(request: request, inspection: inspection, engine: capability.engine, warnings: warnings)
        }
        if inspection.family == .media {
            let media = try mediaBackend()
            try await media.validate(inspection, request: request)
            var warnings = ["Descriptive metadata, chapters and cover artwork are removed from the output."]
            if [.wav, .flac, .m4a, .mp3].contains(request.format) && inspection.videoCodec != nil { warnings.append("This creates an audio-only output; the original video remains unchanged.") }
            if request.format == .wav { warnings.append("WAV output uses 16-bit PCM audio.") }
            if request.format == .mp3 { warnings.append("MP3 is lossy and may lose audio detail. Output preserves mono/stereo and sample rate; encoder delay and padding are recorded for gapless playback.") }
            if request.format == .flac { warnings.append("FLAC compresses PCM audio losslessly; it cannot restore detail already lost in the source recording.") }
            let draft = ConversionPlan(request: request, inspection: inspection, engine: capability.engine, warnings: [])
            if media.canRemux(draft) { warnings.append("Compatible H.264/AAC streams will be copied without re-encoding.") }
            else if [.mp4, .mov].contains(request.format) {
                warnings.append("Video is encoded as compatible SDR H.264; audio uses AAC. Re-encoding may lose detail.")
                if request.goal == .fit { warnings.append("The video bitrate will not go below \(request.options.minimumVideoBitrate) bits per second.") }
            } else if request.format == .m4a { warnings.append("AAC is lossy and may lose audio detail.") }
            return .init(request: request, inspection: inspection, engine: capability.engine, warnings: warnings)
        }
        try ImageBackend.validate(inspection, request: request)
        var warnings = ["Output uses standard sRGB color. Descriptive metadata, including location, is removed."]
        if request.format.isLossyImage { warnings.append("JPEG is lossy; the output may lose image detail.") }
        if inspection.hasAlpha == true && !request.format.supportsAlpha { warnings.append("Transparency will be flattened onto the selected background.") }
        if let bound = request.options.maxDimension, bound < max(inspection.width ?? 0, inspection.height ?? 0) {
            warnings.append("The image will be resized to fit within \(bound) pixels on its longest edge.")
        }
        return .init(request: request, inspection: inspection, engine: capability.engine, warnings: warnings)
    }

    public func run(_ plan: ConversionPlan,
                    progress: @escaping @Sendable (ProgressEvent) -> Void = { _ in }) async throws -> VerifiedResult {
        try await gate.acquire()
        do {
            let result = try await execute(plan, progress: progress)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    private func execute(_ plan: ConversionPlan, progress: @Sendable (ProgressEvent) -> Void) async throws -> VerifiedResult {
        try Task.checkCancellation()
        // Plans are serializable input, not a trust boundary. Revalidate their request
        // and recorded source identity instead of trusting caller-provided engine fields.
        try FileSafety.verifyUnchanged(plan.inspection)
        guard plan.schemaVersion == 1 else { throw FileformError(.invalidRequest, "This plan schema version is not supported.") }
        let validated = try await self.plan(plan.request)
        guard validated.inspection.identity == plan.inspection.identity,
              validated.inspection.input == plan.inspection.input else {
            throw FileformError(.inputChanged, "This plan no longer matches the input. Create a new plan.")
        }
        let request = validated.request
        let inspection = validated.inspection
        progress(.init(.preparing))
        let transaction = try OutputTransaction(destination: request.destination, input: request.input,
                                                collisionPolicy: request.collisionPolicy)
        defer { transaction.cleanup() }
        if validated.engine == "qpdf" { return try await pdfBackend().execute(validated, transaction: transaction, progress: progress) }
        if inspection.family == .media {
            return try await executeMedia(validated, transaction: transaction, progress: progress)
        }
        if validated.engine == "documents" || inspection.family == .table {
            progress(.init(.encoding))
            let candidate = transaction.candidate(0, format: request.format)
            let bytes: Int64
            if validated.engine == "documents" {
                bytes = try DocumentBackend.execute(validated, candidate: candidate)
            } else {
                let table = try TableBackend.read(request.input)
                try TableBackend.encode(table, format: request.format).write(to: candidate, options: .withoutOverwriting)
                let check = try TableBackend.read(candidate, format: request.format.rawValue)
                guard check.records == table.records else { throw FileformError(.verificationFailed, "The converted table did not retain its cell values and rows.") }
                bytes = try FileSafety.identity(candidate).bytes
            }
            progress(.init(.verifying))
            try FileSafety.verifyUnchanged(inspection)
            try Task.checkCancellation()
            progress(.init(.saving))
            let output = try transaction.commit(candidate)
            return .init(status: .succeeded, input: request.input, output: output, inputBytes: inspection.identity.bytes,
                         outputBytes: bytes, format: request.format, warnings: validated.warnings, attempts: 1)
        }
        let rendered = try ImageBackend.render(inspection, options: request.options, format: request.format)
        let qualities: [Double]
        if request.goal == .fit && request.format.isLossyImage {
            qualities = (0...10).map { step in
                request.options.quality - Double(step) / 10 * (request.options.quality - request.options.minimumQuality)
            }
        } else { qualities = [request.options.quality] }
        for (attempt, quality) in qualities.enumerated() {
            try Task.checkCancellation()
            progress(.init(.encoding))
            let candidate = transaction.candidate(attempt, format: request.format)
            try ImageBackend.encode(rendered, format: request.format, quality: quality, destination: candidate)
            try Task.checkCancellation()
            progress(.init(.verifying))
            let bytes = try ImageBackend.verify(candidate, format: request.format, rendered: rendered,
                                                 preserveAlpha: inspection.hasAlpha == true && request.format.supportsAlpha)
            if request.goal == .fit, let limit = request.options.maximumBytes, bytes > limit {
                try FileManager.default.removeItem(at: candidate)
                continue
            }
            if request.goal == .compress && bytes >= inspection.identity.bytes {
                return .init(status: .notSmaller, input: request.input, output: nil,
                             inputBytes: inspection.identity.bytes, outputBytes: nil, format: request.format,
                             warnings: validated.warnings + ["The candidate was not smaller. Your original is retained."], attempts: attempt + 1)
            }
            try FileSafety.verifyUnchanged(inspection)
            try Task.checkCancellation()
            progress(.init(.saving))
            let output = try transaction.commit(candidate)
            return .init(status: .succeeded, input: request.input, output: output, inputBytes: inspection.identity.bytes,
                         outputBytes: bytes, format: request.format, warnings: validated.warnings, attempts: attempt + 1)
        }
        throw FileformError(.targetUnmet, "The complete image could not fit under the byte limit within your quality and size settings. Try a larger limit or explicitly resize the image.")
    }

    private func executeMedia(_ plan: ConversionPlan, transaction: OutputTransaction,
                              progress: @Sendable (ProgressEvent) -> Void) async throws -> VerifiedResult {
        let media = try mediaBackend()
        let request = plan.request
        let count = request.goal == .fit && [.mp4, .mov, .m4a].contains(request.format) ? 6 : 1
        for attempt in 0..<count {
            try Task.checkCancellation()
            progress(.init(.encoding))
            let candidate = transaction.candidate(attempt, format: request.format)
            try await media.encode(plan, destination: candidate, attempt: attempt)
            progress(.init(.verifying))
            let bytes = try await media.verify(candidate, plan: plan)
            if request.goal == .fit, let limit = request.options.maximumBytes, bytes > limit {
                try FileManager.default.removeItem(at: candidate)
                continue
            }
            if request.goal == .compress && bytes >= plan.inspection.identity.bytes {
                return .init(status: .notSmaller, input: request.input, output: nil, inputBytes: plan.inspection.identity.bytes,
                             outputBytes: nil, format: request.format, warnings: plan.warnings + ["The new encoding was not smaller. The original is retained."], attempts: attempt + 1)
            }
            try FileSafety.verifyUnchanged(plan.inspection)
            try Task.checkCancellation()
            progress(.init(.saving))
            let output = try transaction.commit(candidate)
            return .init(status: .succeeded, input: request.input, output: output, inputBytes: plan.inspection.identity.bytes,
                         outputBytes: bytes, format: request.format, warnings: plan.warnings, attempts: attempt + 1)
        }
        throw FileformError(.targetUnmet, "The complete recording could not fit within the byte limit. Increase the limit or explicitly change your constraints.")
    }

    private func validateOptions(_ request: ConversionRequest) throws {
        let options = request.options
        guard (50_000...100_000_000).contains(options.minimumVideoBitrate) else {
            throw FileformError(.invalidRequest, "Minimum video bitrate must be between 50000 and 100000000 bits per second.")
        }
        guard options.quality.isFinite, options.minimumQuality.isFinite,
              (0.05...1).contains(options.quality), (0.05...1).contains(options.minimumQuality),
              options.minimumQuality <= options.quality else {
            throw FileformError(.invalidRequest, "Quality values must be between 0.05 and 1, with minimum quality no higher than quality.")
        }
        if let dimension = options.maxDimension, !(1...32768).contains(dimension) {
            throw FileformError(.invalidRequest, "Maximum dimension must be between 1 and 32768 pixels.")
        }
        if request.goal == .fit {
            guard let maximum = options.maximumBytes, maximum > 0 else {
                throw FileformError(.invalidRequest, "Fit-size needs a positive maximum byte count.")
            }
        } else if options.maximumBytes != nil {
            throw FileformError(.invalidRequest, "A maximum byte count is only valid for fit-size operations.")
        }
        guard request.input.isFileURL, request.destination.isFileURL,
              request.input.standardizedFileURL.resolvingSymlinksInPath() != request.destination.standardizedFileURL.resolvingSymlinksInPath() else {
            throw FileformError(.invalidRequest, "Choose distinct local input and output files.")
        }
    }
}

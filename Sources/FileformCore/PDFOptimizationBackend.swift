// SPDX-License-Identifier: Apache-2.0
import Foundation
import FileformDomain

struct PDFOptimizationBackend {
    let pack: PDFPack
    let worker: NativeWorkerClient
    static let warnings = ["Lossless structural optimization preserves every page, color and metadata. It may raise the PDF version to 1.5. No image resampling or lossy encoding is performed; a size target may be unattainable."]
    static func capability(available: Bool) -> Capability {
        .init(format: .pdf, goals: [.compress, .fit], engine: "qpdf", available: available,
              limitation: "All-page structural optimization only. Requires PDF pack and native worker. Signed, encrypted, annotated, forms, outlines, tagged and interactive PDFs are unsupported. No lossy image resampling; size targets may fail.")
    }
    func validate(_ inspection: Inspection, request: ConversionRequest) async throws {
        guard inspection.family == .pdf, request.format == .pdf, [.compress, .fit].contains(request.goal),
              request.options.pageNumber == nil, request.options.maxDimension == nil, request.options.background == nil else {
            throw FileformError(.unsupported, "PDF optimization requires the complete PDF with no page, image size or background options.")
        }
        _ = try await worker.pdfFingerprint(request.input)
        try FileSafety.verifyUnchanged(inspection)
    }
    func execute(_ plan: ConversionPlan, transaction: OutputTransaction, progress: @Sendable (ProgressEvent) -> Void) async throws -> VerifiedResult {
        // Rehash at execution time; a cached capability is not execution authority.
        let verifiedPack = try PDFPack(directory: pack.directory)
        let sourceDigest = try PDFPack.hash(plan.request.input)
        let before = try await worker.pdfFingerprint(plan.request.input)
        let candidate = transaction.candidate(0, format: .pdf)
        progress(.init(.encoding))
        let check = try await ProcessRunner.run(executable: verifiedPack.qpdf, arguments: ["--check", plan.request.input.path], timeout: 60)
        guard check.status == 0 else { throw FileformError(.unsupported, "The PDF failed strict structural validation.") }
        let result = try await ProcessRunner.run(executable: verifiedPack.qpdf, arguments: ["--compress-streams=y", "--decode-level=generalized", "--recompress-flate", "--compression-level=9", "--object-streams=generate", plan.request.input.path, candidate.path], timeout: 120, monitoredOutput: candidate, maximumOutputBytes: 512 * 1024 * 1024)
        guard result.status == 0 else { throw FileformError(.engineFailed, "PDF optimization failed; no output was saved.") }
        progress(.init(.verifying))
        let outputCheck = try await ProcessRunner.run(executable: verifiedPack.qpdf, arguments: ["--check", candidate.path], timeout: 60)
        guard outputCheck.status == 0, try await worker.pdfFingerprint(candidate) == before else {
            throw FileformError(.verificationFailed, "The optimized PDF did not retain every page's content, geometry and rendered appearance.")
        }
        try FileSafety.verifyUnchanged(plan.inspection)
        guard try PDFPack.hash(plan.request.input) == sourceDigest else { throw FileformError(.inputChanged, "The PDF changed during optimization.") }
        let bytes = try FileSafety.identity(candidate).bytes
        if plan.request.goal == .fit, bytes > (plan.request.options.maximumBytes ?? 0) {
            throw FileformError(.targetUnmet, "The complete PDF could not fit within the byte limit using lossless structural optimization. Increase the limit.")
        }
        if plan.request.goal == .compress, bytes >= plan.inspection.identity.bytes {
            return .init(status: .notSmaller, input: plan.request.input, output: nil, inputBytes: plan.inspection.identity.bytes, outputBytes: nil, format: .pdf, warnings: plan.warnings + ["The optimized candidate was not smaller; the original is retained."], attempts: 1)
        }
        try Task.checkCancellation(); progress(.init(.saving))
        let output = try transaction.commit(candidate)
        return .init(status: .succeeded, input: plan.request.input, output: output, inputBytes: plan.inspection.identity.bytes, outputBytes: bytes, format: .pdf, warnings: plan.warnings, attempts: 1)
    }
}

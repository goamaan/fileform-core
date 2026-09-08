// SPDX-License-Identifier: Apache-2.0
import Foundation
import AppKit
import PDFKit
import Vision
import CoreGraphics
import FileformDomain

enum DocumentBackend {
    static func recognizesPDF(_ input: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: input) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 5)) == Data("%PDF-".utf8)
    }

    static func document(_ input: URL) throws -> PDFDocument {
        guard try FileSafety.identity(input).bytes <= 512 * 1024 * 1024 else {
            throw FileformError(.resourceLimit, "This PDF exceeds the current 512 MB input limit.")
        }
        guard let document = PDFDocument(url: input), !document.isLocked, !document.isEncrypted,
              document.pageCount > 0 else {
            throw FileformError(.unsupported, "This PDF is unreadable or encrypted. Use an unencrypted copy you have permission to process.")
        }
        guard document.pageCount <= 1000 else { throw FileformError(.resourceLimit, "This PDF exceeds the current 1,000-page limit.") }
        return document
    }

    static func inspect(_ input: URL, identity: FileIdentity) throws -> Inspection {
        let document = try document(input)
        return .init(input: input, identity: identity, family: .pdf, detectedType: "com.adobe.pdf", pageCount: document.pageCount)
    }

    static func capabilities(for inspection: Inspection?) -> [Capability] {
        if inspection?.family == .image {
            return [
                .init(format: .pdf, goals: [.convert], engine: "documents", available: true, limitation: "Create a one-page PDF from the image."),
                .init(format: .txt, goals: [.convert], engine: "documents", available: true, limitation: "Recognize text locally; review spelling and reading order.")
            ]
        }
        return [.txt, .png, .jpeg, .tiff, .pdf].map { format in
            .init(format: format, goals: [.convert], engine: "documents", available: true,
                  limitation: format == .txt ? "Extract text from all pages, or a selected page. Scans use local OCR." : "Choose one page to export; multi-page PDFs are never silently reduced to the first page.")
        }
    }

    static func validate(_ inspection: Inspection, request: ConversionRequest) throws {
        guard request.goal == .convert else { throw FileformError(.unsupported, "This document operation does not support compression or a size limit.") }
        if inspection.family == .image {
            guard [.pdf, .txt].contains(request.format), inspection.frameCount == 1,
                  inspection.bitDepth ?? 8 <= 8, inspection.warnings.isEmpty else {
                throw FileformError(.unsupported, "This image needs a preservation workflow that is not available for document output yet.")
            }
            guard request.options.pageNumber == nil else { throw FileformError(.invalidRequest, "Page selection is only available for PDF inputs.") }
            return
        }
        guard inspection.family == .pdf else { throw FileformError(.unsupported, "Choose a PDF or still image for this operation.") }
        let count = inspection.pageCount ?? 0
        if let page = request.options.pageNumber, !(1...max(1, count)).contains(page) {
            throw FileformError(.invalidRequest, "Choose a page between 1 and \(count).")
        }
        if request.format != .txt && count > 1 && request.options.pageNumber == nil {
            throw FileformError(.invalidRequest, "Choose which PDF page to export. The other pages will remain in your original.")
        }
        if request.format == .txt && count > 100 && request.options.pageNumber == nil {
            throw FileformError(.resourceLimit, "Text extraction currently handles up to 100 pages at once. Choose a page to extract.")
        }
        guard request.options.background == nil else { throw FileformError(.invalidRequest, "A PDF page already has its own background.") }
        if request.format == .txt && request.options.maxDimension != nil {
            throw FileformError(.invalidRequest, "Image resizing is not an option for text extraction.")
        }
    }

    static func warnings(_ inspection: Inspection, request: ConversionRequest) -> [String] {
        if request.format == .txt {
            return ["Text is extracted locally. Scanned content uses OCR; review spelling, numbers and reading order.",
                    "Images, formatting and interactive PDF features are not included in the text file."]
        }
        if inspection.family == .image {
            return ["Creates a one-page PDF from the image. Descriptive image metadata is removed; image dimensions define the page size."]
        }
        if request.format == .pdf {
            return ["Creates a new PDF containing the selected page. Document-level bookmarks, signatures and form behavior are not guaranteed to carry over."]
        }
        return ["Exports the selected PDF page as an image. Text becomes pixels and interactive features are removed."]
    }

    static func execute(_ plan: ConversionPlan, candidate: URL) throws -> Int64 {
        let request = plan.request
        if request.format == .txt {
            let text: String
            if plan.inspection.family == .image {
                let rendered = try ImageBackend.render(plan.inspection, options: .init(maxDimension: 4096, background: .white), format: .jpeg)
                text = try recognizeText(rendered)
            } else {
                let document = try document(request.input)
                let indexes = request.options.pageNumber.map { [$0 - 1] } ?? Array(0..<document.pageCount)
                var pages = [String]()
                for index in indexes {
                    try Task.checkCancellation()
                    guard let page = document.page(at: index) else { throw FileformError(.verificationFailed, "A PDF page could not be read.") }
                    var content = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if content.isEmpty { content = try recognizeText(render(page, maximumDimension: 4096)) }
                    pages.append(indexes.count > 1 ? "Page \(index + 1)\n\n\(content.isEmpty ? "[No text recognized on this page.]" : content)" : content)
                }
                text = pages.joined(separator: "\n\n\u{000C}\n\n")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FileformError(.unsupported, "No text could be recognized. Try a sharper or higher-contrast scan.")
            }
            let data = Data((text + "\n").utf8)
            try data.write(to: candidate, options: .withoutOverwriting)
            guard try Data(contentsOf: candidate) == data else { throw FileformError(.verificationFailed, "The text output could not be verified.") }
        } else if plan.inspection.family == .image && request.format == .pdf {
            let image = try ImageBackend.render(plan.inspection, options: request.options, format: .png)
            let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            guard let page else { throw FileformError(.engineFailed, "Could not create a PDF page from this image.") }
            let document = PDFDocument(); document.insert(page, at: 0)
            guard document.write(to: candidate), let check = PDFDocument(url: candidate), check.pageCount == 1 else {
                throw FileformError(.verificationFailed, "The generated PDF failed page-count verification.")
            }
            _ = try render(try requiredPage(check, at: 0), maximumDimension: 256)
        } else {
            let document = try document(request.input)
            let index = (request.options.pageNumber ?? 1) - 1
            let page = try requiredPage(document, at: index)
            if request.format == .pdf {
                let text = page.string
                let bounds = page.bounds(for: .mediaBox)
                let output = PDFDocument()
                guard let copy = page.copy() as? PDFPage else { throw FileformError(.engineFailed, "Could not copy the selected PDF page.") }
                output.insert(copy, at: 0)
                guard output.write(to: candidate), let check = PDFDocument(url: candidate), check.pageCount == 1,
                      let checkedPage = check.page(at: 0), checkedPage.bounds(for: .mediaBox) == bounds, checkedPage.string == text else {
                    throw FileformError(.verificationFailed, "The selected-page PDF failed structure or text verification.")
                }
            } else {
                let image = try render(page, maximumDimension: request.options.maxDimension ?? 2048)
                try ImageBackend.encode(image, format: request.format, quality: request.options.quality, destination: candidate)
                _ = try ImageBackend.verify(candidate, format: request.format, rendered: image, preserveAlpha: false)
            }
        }
        try Task.checkCancellation()
        return try FileSafety.identity(candidate).bytes
    }

    private static func requiredPage(_ document: PDFDocument, at index: Int) throws -> PDFPage {
        guard let page = document.page(at: index) else { throw FileformError(.unsupported, "The selected PDF page does not exist.") }
        return page
    }
    private static func render(_ page: PDFPage, maximumDimension: Int) throws -> CGImage {
        try Task.checkCancellation()
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              (1...8192).contains(maximumDimension) else { throw FileformError(.resourceLimit, "This page has invalid dimensions or the requested image is too large.") }
        let ratio = Double(maximumDimension) / max(bounds.width, bounds.height)
        let size = NSSize(width: max(1, bounds.width * ratio), height: max(1, bounds.height * ratio))
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw FileformError(.engineFailed, "The PDF page could not be rendered.")
        }
        return image
    }
    private static func recognizeText(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import Testing
import FileformDomain
@testable import FileformCore

extension Fixture {
    func pdf() throws -> URL {
        let output = url("notes.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: output as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in ["First page of Fileform notes", "Second page: project total 42.50"] {
            context.beginPDFPage(nil)
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            ])
            context.textPosition = CGPoint(x: 40, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
            context.endPDFPage()
        }
        context.closePDF()
        return output
    }

    func receipt() throws -> URL {
        let context = try #require(CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8, bytesPerRow: 1200 * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        for (index, text) in ["Fileform test receipt", "Total: 42.50", "Thank you"].enumerated() {
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 52, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 70, y: 450 - index * 120)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        let image = try #require(context.makeImage())
        let output = url("receipt.png")
        try ImageBackend.encode(image, format: .png, quality: 1, destination: output)
        return output
    }
}

@Test func pdfTextExtractionIncludesEveryPage() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.pdf(); let before = try Data(contentsOf: input)
    let engine = ConversionEngine()
    let inspection = try await engine.inspect(input)
    #expect(inspection.family == .pdf && inspection.pageCount == 2)
    let plan = try await engine.plan(.init(input: input, destination: fixture.url("notes.txt"), format: .txt))
    let result = try await engine.run(plan)
    let text = try String(contentsOf: #require(result.output), encoding: .utf8)
    #expect(text.contains("First page of Fileform notes"))
    #expect(text.contains("Second page: project total 42.50"))
    #expect(try Data(contentsOf: input) == before)
}

@Test func pdfPageExportRequiresExplicitSelection() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.pdf(); let engine = ConversionEngine()
    await #expect(throws: FileformError.self) {
        try await engine.plan(.init(input: input, destination: fixture.url("page.png"), format: .png))
    }
    for format in [OutputFormat.png, .pdf] {
        let plan = try await engine.plan(.init(input: input, destination: fixture.url("page.\(format.fileExtension)"), format: format,
                                               options: .init(pageNumber: 2)))
        let result = try await engine.run(plan)
        #expect(result.status == .succeeded)
        if format == .pdf {
            let output = try #require(result.output)
            let document = try #require(PDFDocument(url: output))
            #expect(document.pageCount == 1)
            #expect(document.string?.contains("Second page") == true)
            #expect(document.string?.contains("First page") == false)
        }
    }
}

@Test func imageCanBecomePdfOrLocallyRecognizedText() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.receipt(); let engine = ConversionEngine()
    let plan = try await engine.plan(.init(input: input, destination: fixture.url("receipt.txt"), format: .txt))
    let result = try await engine.run(plan)
    let text = try String(contentsOf: #require(result.output), encoding: .utf8)
    #expect(text.contains("42.50"))
    let pdf = try await engine.plan(.init(input: input, destination: fixture.url("receipt.pdf"), format: .pdf))
    let pdfResult = try await engine.run(pdf)
    let pdfURL = try #require(pdfResult.output)
    let checkedPDF = try #require(PDFDocument(url: pdfURL))
    #expect(checkedPDF.pageCount == 1)
}

@Test func csvQuotingUnicodeAndNewlinesRoundTrip() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = fixture.url("table.csv")
    try Data("\u{FEFF}name,note,empty\r\n\"Lee, Jo\",\"Line one\nLine \"\"two\"\"\",\r\n日本語,yes,\r\n".utf8).write(to: input)
    let original = try TableBackend.read(input)
    let engine = ConversionEngine()
    for format in [OutputFormat.tsv, .json] {
        let plan = try await engine.plan(.init(input: input, destination: fixture.url("table.\(format.fileExtension)"), format: format))
        let result = try await engine.run(plan)
        #expect(try TableBackend.read(#require(result.output)).records == original.records)
    }
}

@Test func jsonLargeNumbersAreNotRounded() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = fixture.url("table.json")
    try Data("[{\"id\":90071992547409931234567890,\"amount\":1.234567890123456789e-20,\"active\":true}]".utf8).write(to: input)
    let engine = ConversionEngine()
    let plan = try await engine.plan(.init(input: input, destination: fixture.url("table.csv"), format: .csv))
    let result = try await engine.run(plan)
    let text = try String(contentsOf: #require(result.output), encoding: .utf8)
    #expect(text.contains("90071992547409931234567890"))
    #expect(text.contains("1.234567890123456789e-20"))
}

@Test(arguments: ["a,a\n1,2\n", "a,b\n1\n", "a,b\n\"unfinished,2", "a,b\n\"hello\"x,2"])
func malformedTablesAreRejected(_ text: String) throws {
    #expect(throws: FileformError.self) { try TableBackend.delimited(text, separator: ",") }
}

@Test func nestedJsonAndDuplicateColumnsAreRejected() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = fixture.url("table.json")
    let engine = ConversionEngine()
    for text in ["[{\"a\":{\"nested\":1}}]", "[{\"a\":1,\"a\":2}]", "[{\"a\":1},{\"b\":2}]"] {
        try Data(text.utf8).write(to: input)
        await #expect(throws: FileformError.self) { try await engine.inspect(input) }
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import PDFKit
import CryptoKit
import FileformDomain

/// Runs only inside the bounded native worker for structural optimization.
enum PDFStructuralFingerprint {
    private final class Scan {
        var seen = Set<CGPDFDictionaryRef>()
        var count = 0
        var rejected = false
        func object(_ value: CGPDFObjectRef, depth: Int) {
            count += 1
            guard count <= 100_000, depth <= 64 else { rejected = true; return }
            var dictionary: CGPDFDictionaryRef?
            var array: CGPDFArrayRef?
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary { visit(dictionary, depth: depth) }
            else if CGPDFObjectGetValue(value, .array, &array), let array {
                for index in 0..<CGPDFArrayGetCount(array) {
                    var child: CGPDFObjectRef?
                    if CGPDFArrayGetObject(array, index, &child), let child { object(child, depth: depth + 1) }
                    if rejected { return }
                }
            } else if CGPDFObjectGetValue(value, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) { visit(dictionary, depth: depth) }
        }
        func visit(_ dictionary: CGPDFDictionaryRef, depth: Int) {
            guard seen.insert(dictionary).inserted else { return }
            guard depth <= 64 else { rejected = true; return }
            // These features require additional semantic preservation checks.
            let blocked = ["AcroForm", "Annots", "ByteRange", "Perms", "JavaScript", "JS", "OpenAction", "AA", "EmbeddedFiles", "AF", "StructTreeRoot", "OCProperties", "Collection", "XFA", "Encrypt", "Outlines"]
            for key in blocked {
                var value: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(dictionary, key, &value) { rejected = true; return }
            }
            let context = Context(scan: self, depth: depth)
            CGPDFDictionaryApplyFunction(dictionary, { key, value, raw in
                let context = Unmanaged<Context>.fromOpaque(raw!).takeUnretainedValue()
                if !context.scan.rejected { context.scan.object(value, depth: context.depth + 1) }
            }, Unmanaged.passUnretained(context).toOpaque())
        }
    }
    private final class Context {
        let scan: Scan; let depth: Int
        init(scan: Scan, depth: Int) { self.scan = scan; self.depth = depth }
    }
    private final class Entries { var values: [(String, CGPDFObjectRef)] = [] }
    private static func infoBytes(_ dictionary: CGPDFDictionaryRef) throws -> Data {
        let entries = Entries()
        CGPDFDictionaryApplyFunction(dictionary, { key, value, raw in
            Unmanaged<Entries>.fromOpaque(raw!).takeUnretainedValue().values.append((String(cString: key), value))
        }, Unmanaged.passUnretained(entries).toOpaque())
        guard entries.values.count <= 1000 else { throw FileformError(.resourceLimit, "Too many PDF metadata fields.") }
        var result = Data()
        for (key, value) in entries.values.sorted(by: { $0.0 < $1.0 }) {
            let payload: Data
            switch CGPDFObjectGetType(value) {
            case .string:
                var text: CGPDFStringRef?
                guard CGPDFObjectGetValue(value, .string, &text), let text, let pointer = CGPDFStringGetBytePtr(text), CGPDFStringGetLength(text) <= 1024 * 1024 else { throw FileformError(.unsupported, "Unsupported PDF metadata string.") }
                payload = Data(bytes: pointer, count: CGPDFStringGetLength(text))
            case .integer:
                var number: CGPDFInteger = 0; CGPDFObjectGetValue(value, .integer, &number); payload = Data("integer:\(number)".utf8)
            case .real:
                var number: CGPDFReal = 0; CGPDFObjectGetValue(value, .real, &number); guard number.isFinite else { throw FileformError(.unsupported, "Invalid PDF metadata number.") }; payload = Data("real:\(number)".utf8)
            case .boolean:
                var flag: CGPDFBoolean = 0; CGPDFObjectGetValue(value, .boolean, &flag); payload = Data("boolean:\(flag)".utf8)
            case .null: payload = Data("null".utf8)
            case .name:
                var name: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(value, .name, &name), let name else { throw FileformError(.unsupported, "Invalid PDF metadata name.") }; payload = Data(("name:" + String(cString: name)).utf8)
            default: throw FileformError(.unsupported, "Complex PDF metadata requires an unsupported preservation workflow.")
            }
            result.append(Data("\(key.utf8.count):\(key):\(CGPDFObjectGetType(value).rawValue):\(payload.count):".utf8)); result.append(payload)
        }
        return result
    }
    static func compute(_ input: URL) throws -> String {
        let pdf = try DocumentBackend.document(input)
        guard let cg = CGPDFDocument(input as CFURL), !cg.isEncrypted, let catalog = cg.catalog else {
            throw FileformError(.unsupported, "Encrypted or unreadable PDF.")
        }
        let scan = Scan(); scan.visit(catalog, depth: 0)
        guard !scan.rejected else { throw FileformError(.unsupported, "This PDF contains unsupported interactive, signed, tagged or complex document features.") }
        var hash = SHA256()
        func add(_ data: Data) { var size = UInt64(data.count).bigEndian; withUnsafeBytes(of: &size) { hash.update(data: Data($0)) }; hash.update(data: data) }
        if let info = cg.info { add(try infoBytes(info)) } else { add(Data()) }
        var metadataObject: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(catalog, "Metadata", &metadataObject), let metadataObject {
            var metadata: CGPDFStreamRef?
            guard CGPDFObjectGetValue(metadataObject, .stream, &metadata), let metadata else { throw FileformError(.unsupported, "Invalid PDF XMP metadata object.") }
            var format = CGPDFDataFormat.raw
            guard let bytes = CGPDFStreamCopyData(metadata, &format), format == .raw, CFDataGetLength(bytes) <= 16 * 1024 * 1024 else { throw FileformError(.unsupported, "Unsupported PDF XMP metadata.") }
            add(bytes as Data)
        } else { add(Data()) }
        add(Data("pages:\(pdf.pageCount)".utf8))
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index), let ref = cg.page(at: index + 1) else { throw FileformError(.verificationFailed, "Missing PDF page.") }
            add(Data((page.string ?? "").utf8))
            add(Data("rotation:\(page.rotation)".utf8))
            for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                let b = page.bounds(for: box)
                guard [b.minX,b.minY,b.width,b.height].allSatisfy({ $0.isFinite }), b.width > 0, b.height > 0 else { throw FileformError(.unsupported, "Invalid PDF page bounds.") }
                add(Data("\(b.minX),\(b.minY),\(b.width),\(b.height)".utf8))
            }
            // Full content stream bytes, independently decoded by CoreGraphics.
            var contents: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(ref.dictionary!, "Contents", &contents), let contents {
                func streamBytes(_ object: CGPDFObjectRef) throws {
                    var stream: CGPDFStreamRef?
                    var format = CGPDFDataFormat.raw
                    guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                          let bytes = CGPDFStreamCopyData(stream, &format), format == .raw else { throw FileformError(.unsupported, "Undecodable PDF content stream.") }
                    guard CFDataGetLength(bytes) <= 64 * 1024 * 1024 else { throw FileformError(.resourceLimit, "PDF content stream exceeds verification limit.") }
                    add(bytes as Data)
                }
                var array: CGPDFArrayRef?
                if CGPDFObjectGetValue(contents, .array, &array), let array {
                    guard CGPDFArrayGetCount(array) <= 10_000 else { throw FileformError(.resourceLimit, "Too many PDF content streams.") }
                    for i in 0..<CGPDFArrayGetCount(array) { var item: CGPDFObjectRef?; guard CGPDFArrayGetObject(array, i, &item), let item else { throw FileformError(.unsupported, "Invalid PDF content.") }; try streamBytes(item) }
                } else { try streamBytes(contents) }
            }
            let bounds = ref.getBoxRect(.mediaBox)
            let scale = min(2.0, 2048 / max(bounds.width, bounds.height))
            let width = max(1, Int(ceil(bounds.width * scale))), height = max(1, Int(ceil(bounds.height * scale)))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FileformError(.resourceLimit, "PDF verification allocation failed.") }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.concatenate(ref.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true)); context.drawPDFPage(ref)
            guard let pixels = context.data else { throw FileformError(.verificationFailed, "PDF rendering failed.") }
            add(Data(bytes: pixels, count: width * height * 4))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

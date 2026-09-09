// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreFoundation
import FileformDomain

/// Resource discovery deliberately does not infer paint occurrences or parse content.
struct PDFImageGraph {
    struct Image {
        var candidate: PDFEmbeddedImageCandidate
        let reference: String
        let channels: Int
        let softMask: String?
    }
    let objects: [String: Any]
    let pageObjects: [String]
    init(data: Data) throws {
        guard data.count <= 32 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let qpdf = root["qpdf"] as? [[String: Any]], qpdf.count == 2,
              let pages = root["pages"] as? [[String: Any]], pages.count <= 100_000,
              (root["encrypt"] as? [String: Any])?["encrypted"] as? Bool == false else {
            throw FileformError(.unsupported, "Image extraction needs an unencrypted PDF and bounded object metadata.")
        }
        guard qpdf[1].count <= 100_000 else { throw FileformError(.resourceLimit, "PDF object inventory exceeds 100000 objects.") }
        objects = qpdf[1]
        pageObjects = try pages.map { page in
            guard let value = page["object"] as? String, Self.reference(value) != nil else { throw FileformError(.verificationFailed, "Invalid PDF page object.") }
            return value
        }
    }
    static func reference(_ value: String) -> (Int, Int)? {
        let parts = value.split(separator: " ")
        guard parts.count == 3, parts[2] == "R", let number = Int(parts[0]), let generation = Int(parts[1]), number > 0, number <= Int(Int32.max), (0...65535).contains(generation) else { return nil }
        return (number, generation)
    }
    func resolve(_ value: Any?, depth: Int = 0, visited: Set<String> = []) throws -> Any? {
        guard depth <= 32 else { throw FileformError(.resourceLimit, "PDF indirect-object depth exceeds 32.") }
        guard let ref = value as? String, Self.reference(ref) != nil else { return value }
        guard !visited.contains(ref), let object = objects["obj:" + ref] as? [String: Any] else { throw FileformError(.verificationFailed, "Missing or cyclic PDF object reference.") }
        if let stream = object["stream"] as? [String: Any] { return stream["dict"] }
        return try resolve(object["value"], depth: depth + 1, visited: visited.union([ref]))
    }
    func dict(_ value: Any?) throws -> [String: Any] { try resolve(value) as? [String: Any] ?? [:] }
    func number(_ value: Any?) throws -> Int? {
        guard let n = try resolve(value) as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue >= 0, n.doubleValue <= Double(Int32.max), n.doubleValue.rounded() == n.doubleValue else { return nil }
        return n.intValue
    }
    func text(_ value: Any?) throws -> String? { try resolve(value) as? String }
    func filters(_ d: [String: Any]) throws -> [String] {
        let value = try resolve(d["/Filter"])
        if value == nil || value is NSNull { return [] }
        if let name = value as? String { return [String(name.prefix(128))] }
        guard let list = value as? [Any], list.count <= 16 else { return ["unsupported-filter-definition"] }
        return try list.map { String((try text($0) ?? "unsupported-filter-definition").prefix(128)) }
    }
    func images(sourceID: String, pages: [PageReference]) throws -> [Image] {
        var found: [Image] = [], indexes: [String: Int] = [:], visits = 0, provenanceBytes = 0
        var foundPaths: [String: Set<String>] = [:], foundPages: [String: Set<Int>] = [:]
        func walk(_ resources: Any?, page: PageReference, path: [String], forms: Set<String>) throws {
            try Task.checkCancellation()
            guard path.count <= 32 else { throw FileformError(.resourceLimit, "PDF Form nesting exceeds 32.") }
            let effective = try dict(resources), xobjects = try dict(effective["/XObject"])
            for name in xobjects.keys.sorted() {
                try Task.checkCancellation()
                visits += 1
                guard visits <= 100_000 else { throw FileformError(.resourceLimit, "PDF resource traversal exceeds 100000 references.") }
                guard name.utf8.count <= 256, let ref = xobjects[name] as? String, let (number, generation) = Self.reference(ref) else { throw FileformError(.unsupported, "PDF XObjects need bounded indirect object references.") }
                let d = try dict(ref), subtype = try text(d["/Subtype"])
                if subtype == "/Form" {
                    if forms.contains(ref) { continue }
                    try walk(d["/Resources"] ?? resources, page: page, path: path + [name], forms: forms.union([ref]))
                } else if subtype == "/Image" {
                    let location = "page \(page.pageIndex + 1): " + (path + [name]).joined(separator: " → ")
                    provenanceBytes += location.utf8.count
                    guard location.utf8.count <= 4096, provenanceBytes <= 4 * 1024 * 1024 else { throw FileformError(.resourceLimit, "PDF image provenance exceeds its metadata budget.") }
                    if let index = indexes[ref] {
                        if foundPages[ref, default: []].insert(page.pageIndex).inserted { found[index].candidate.resourcePages.append(page) }
                        if foundPaths[ref, default: []].insert(location).inserted { found[index].candidate.resourcePaths.append(location) }
                    } else {
                        guard found.count < 1000 else { throw FileformError(.resourceLimit, "Extract at most 1000 unique images per source.") }
                        let width = try self.number(d["/Width"]), height = try self.number(d["/Height"]), filters = try self.filters(d)
                        let cs = try text(d["/ColorSpace"]), channels = cs == "/DeviceRGB" ? 3 : 1
                        let mask = d["/SMask"] as? String
                        var reason: String?
                        if (objects["obj:" + ref] as? [String: Any])?["stream"] == nil { reason = "Image object is not a stream." }
                        else if width == nil || height == nil || width! == 0 || height! == 0 { reason = "Invalid intrinsic dimensions." }
                        else if width! > 16384 || height! > 16384 || Int64(width!) * Int64(height!) > 64_000_000 { reason = "Intrinsic image exceeds 16384 pixels per edge or 64 million pixels." }
                        else if (try resolve(d["/ImageMask"])) as? Bool == true { reason = "Stencil image masks are unsupported." }
                        else if try self.number(d["/BitsPerComponent"]) != 8 { reason = "Only 8-bit image samples are supported." }
                        else if !["/DeviceRGB", "/DeviceGray"].contains(cs ?? "") { reason = "Unsupported color space; only DeviceRGB and DeviceGray are supported." }
                        else if d["/Decode"] != nil { reason = "Custom Decode arrays are unsupported." }
                        else if d["/Mask"] != nil { reason = "Explicit image or color-key masks are unsupported." }
                        else if d["/Alternates"] != nil || d["/OPI"] != nil { reason = "Alternate image representations are unsupported." }
                        var softMask: String?
                        let jpeg = filters == ["/DCTDecode"]
                        if reason == nil, let mask, mask != "/None" {
                            if jpeg { reason = "JPEG with a soft mask cannot preserve encoded bytes faithfully." }
                            else if Self.reference(mask) == nil { reason = "Unsupported soft-mask reference." }
                            else {
                                let md = try dict(mask)
                                if try text(md["/Subtype"]) != "/Image" || self.number(md["/Width"]) != width || self.number(md["/Height"]) != height || self.number(md["/BitsPerComponent"]) != 8 || text(md["/ColorSpace"]) != "/DeviceGray" { reason = "Soft mask must be a same-size 8-bit DeviceGray image." }
                                else if md["/Matte"] != nil || md["/Decode"] != nil || md["/Mask"] != nil || md["/SMask"] != nil || md["/ImageMask"] != nil { reason = "Soft-mask Matte, Decode or nested-mask semantics are unsupported." }
                                else if try !supportedSamples(md) { reason = "Soft-mask filters or predictor parameters are unsupported." }
                                else { softMask = mask }
                            }
                        } else if reason == nil, d["/SMask"] != nil, mask == nil { reason = "Unsupported soft-mask definition." }
                        if reason == nil {
                            if jpeg {
                                if d["/DecodeParms"] != nil, !(d["/DecodeParms"] is NSNull) { reason = "JPEG decode parameters are unsupported." }
                            } else if try !supportedSamples(d) { reason = "Unsupported image filters or predictor parameters." }
                        }
                        let candidate = PDFEmbeddedImageCandidate(sourceID: sourceID, objectNumber: number, generation: generation,
                            resourcePages: [page], resourcePaths: [location], width: width, height: height, filters: filters,
                            colorSpace: cs.map { String($0.prefix(128)) }, encodingOutcome: reason == nil ? (jpeg ? .preservedEncodedBytes : .reconstructedPixels) : nil,
                            alphaHandling: reason == nil ? (softMask == nil ? "opaque" : "straight alpha from soft mask; hidden RGB preserved") : nil, skipReason: reason)
                        foundPaths[ref] = [location]; foundPages[ref] = [page.pageIndex]
                        indexes[ref] = found.count
                        found.append(.init(candidate: candidate, reference: ref, channels: channels, softMask: softMask))
                    }
                }
            }
        }
        for page in pages {
            guard page.pageIndex < pageObjects.count else { throw FileformError(.invalidRequest, "A selected page is outside its PDF source.") }
            var current = pageObjects[page.pageIndex], seen = Set<String>(), resources: Any?
            while true {
                guard seen.count < 64, seen.insert(current).inserted else { throw FileformError(.resourceLimit, "Invalid or cyclic PDF page ancestry.") }
                let d = try dict(current)
                if let r = d["/Resources"] { resources = r; break }
                guard let parent = d["/Parent"] as? String else { break }
                current = parent
            }
            try walk(resources, page: page, path: [], forms: [])
        }
        return found
    }
    private func supportedSamples(_ d: [String: Any]) throws -> Bool {
        let filters = try filters(d)
        guard filters.allSatisfy({ ["/FlateDecode", "/ASCII85Decode", "/ASCIIHexDecode", "/RunLengthDecode"].contains($0) }) else { return false }
        // Predictor support is opt-in after exact sample fixtures; reject rather than silently reinterpret.
        guard let parameters = try resolve(d["/DecodeParms"]), !(parameters is NSNull) else { return true }
        if let array = parameters as? [Any] { return array.count == filters.count && array.allSatisfy { $0 is NSNull } }
        return (parameters as? [String: Any])?.isEmpty == true
    }
}

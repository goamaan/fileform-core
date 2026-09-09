// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Object identity is scoped to sourceID, including the PDF object generation.
/// Provenance means referenced by page resources, not verified paint occurrences.
public struct PDFEmbeddedImageCandidate: Codable, Equatable, Sendable {
    public enum EncodingOutcome: String, Codable, Sendable { case preservedEncodedBytes, reconstructedPixels }
    public let sourceID: String
    public let objectNumber: Int
    public let generation: Int
    public var resourcePages: [PageReference]
    public var resourcePaths: [String]
    public let width: Int?
    public let height: Int?
    public let filters: [String]
    public let colorSpace: String?
    public var encodingOutcome: EncodingOutcome?
    public var alphaHandling: String?
    public var skipReason: String?
    public var artifactName: String?
    public var byteCount: Int64?
    public var sha256: String?
    public init(sourceID: String, objectNumber: Int, generation: Int, resourcePages: [PageReference], resourcePaths: [String], width: Int?, height: Int?, filters: [String], colorSpace: String?, encodingOutcome: EncodingOutcome?, alphaHandling: String?, skipReason: String?) {
        self.sourceID = sourceID; self.objectNumber = objectNumber; self.generation = generation
        self.resourcePages = resourcePages; self.resourcePaths = resourcePaths; self.width = width; self.height = height
        self.filters = filters; self.colorSpace = colorSpace; self.encodingOutcome = encodingOutcome
        self.alphaHandling = alphaHandling; self.skipReason = skipReason
    }
}
public struct PDFImageExtractionDetails: Codable, Equatable, Sendable {
    public let candidates: [PDFEmbeddedImageCandidate]
    public var discoveredCount: Int { candidates.count }
    public var supportedCount: Int { candidates.filter { $0.skipReason == nil }.count }
    public var skippedCount: Int { candidates.filter { $0.skipReason != nil }.count }
    public init(candidates: [PDFEmbeddedImageCandidate]) { self.candidates = candidates }
    private enum CodingKeys: String, CodingKey { case candidates, discoveredCount, supportedCount, skippedCount }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        candidates = try values.decode([PDFEmbeddedImageCandidate].self, forKey: .candidates)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(candidates, forKey: .candidates)
        try values.encode(discoveredCount, forKey: .discoveredCount)
        try values.encode(supportedCount, forKey: .supportedCount)
        try values.encode(skippedCount, forKey: .skippedCount)
    }
}

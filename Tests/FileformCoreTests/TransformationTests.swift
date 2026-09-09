// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import FileformDomain

private let contractAsset = AssetReference(id: "source", url: URL(fileURLWithPath: "/tmp/fileform-contract/source.pdf"))
private let contractPage = PageReference(sourceID: "source", pageIndex: 0)

private func contractRequest(_ operation: TransformationOperation,
                             assets: [AssetReference] = [contractAsset],
                             format: OutputFormat = .pdf,
                             cardinality: OutputCardinality = .file) throws -> TransformationRequest {
    try TransformationRequest(assets: assets, operation: operation,
                              output: .init(destination: URL(fileURLWithPath: "/tmp/fileform-contract/output"),
                                            format: format, cardinality: cardinality))
}

@Test func transformationRequestsRoundTripAllSixOperations() throws {
    let interval = MediaInterval(start: .init(ticks: 1, timescale: 24), end: .init(ticks: 75, timescale: 24))
    let requests = try [
        contractRequest(.conversion(.init()), format: .png),
        contractRequest(.pdfComposition(pages: [contractPage])),
        contractRequest(.pdfSplit(groups: [[contractPage], [contractPage]]), cardinality: .directory),
        contractRequest(.mediaTrim(interval: interval, mode: .copy, audioStream: 2), format: .mp4),
        contractRequest(.imageCrop(rectangle: .init(x: 7, y: 9, width: 30, height: 40),
                                   conversion: .init(color: .preserve, metadata: .preserve)), format: .png),
        contractRequest(.fetch(url: URL(string: "https://example.com/recording.mp4")!, maximumBytes: 1_000_000),
                        assets: [], format: .mp4)
    ]
    #expect(Set(requests.map { $0.operation.id.rawValue }).count == 6)
    for request in requests {
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(TransformationRequest.self, from: encoded)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.assets == request.assets)
        #expect(decoded.operation == request.operation)
        #expect(decoded.output == request.output)
        #expect(decoded.fidelity == request.fidelity)
        #expect(decoded.collisionPolicy == request.collisionPolicy)
    }
}

@Test func transformationDecodingRejectsUnknownVersionsAndOperations() throws {
    let request = try contractRequest(.conversion(.init()))
    let data = try JSONEncoder().encode(request)
    let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for version in [-1, 0, 2, Int.max] {
        var mutated = original
        mutated["schemaVersion"] = version
        let invalid = try JSONSerialization.data(withJSONObject: mutated)
        #expect(throws: FileformError.self) { try JSONDecoder().decode(TransformationRequest.self, from: invalid) }
    }
    var unknown = original
    unknown["operation"] = ["executeArbitraryCommand": ["command": "unused"]]
    let invalid = try JSONSerialization.data(withJSONObject: unknown)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(TransformationRequest.self, from: invalid) }
}

@Test func pageBindingsRejectAmbiguityAndPreserveOrderedDuplicates() throws {
    let other = AssetReference(id: "other", url: URL(fileURLWithPath: "/tmp/fileform-contract/other.pdf"))
    #expect(throws: FileformError.self) {
        try contractRequest(.pdfComposition(pages: [contractPage]), assets: [contractAsset, contractAsset])
    }
    for page in [PageReference(sourceID: "missing", pageIndex: 0),
                 PageReference(sourceID: "source", pageIndex: -1),
                 PageReference(sourceID: "source", pageIndex: 0, clockwiseRotation: 45)] {
        #expect(throws: FileformError.self) { try contractRequest(.pdfComposition(pages: [page])) }
    }
    let pages = [PageReference(sourceID: "other", pageIndex: 4, clockwiseRotation: 270),
                 contractPage, contractPage, PageReference(sourceID: "source", pageIndex: 2)]
    let composition = try contractRequest(.pdfComposition(pages: pages), assets: [contractAsset, other])
    let decoded = try JSONDecoder().decode(TransformationRequest.self, from: JSONEncoder().encode(composition))
    #expect(decoded.operation == .pdfComposition(pages: pages))
    let groups = [[pages[0], pages[1]], [pages[2]], [pages[0], pages[3]]]
    let split = try contractRequest(.pdfSplit(groups: groups), assets: [contractAsset, other], cardinality: .directory)
    #expect(try JSONDecoder().decode(TransformationRequest.self, from: JSONEncoder().encode(split)).operation == .pdfSplit(groups: groups))
    #expect(throws: FileformError.self) { try contractRequest(.pdfComposition(pages: [])) }
    #expect(throws: FileformError.self) { try contractRequest(.pdfSplit(groups: []), cardinality: .directory) }
    #expect(throws: FileformError.self) { try contractRequest(.pdfSplit(groups: [[contractPage], []]), cardinality: .directory) }
}

@Test func mediaIntervalsRequireNonemptyBoundedHalfOpenRanges() throws {
    let zero = MediaTime(ticks: 0, timescale: 1)
    let one = MediaTime(ticks: 1, timescale: 1)
    let two = MediaTime(ticks: 2, timescale: 1)
    #expect(throws: FileformError.self) { try MediaInterval(start: one, end: one).validate() }
    #expect(throws: FileformError.self) { try MediaInterval(start: two, end: one).validate() }
    #expect(throws: FileformError.self) { try MediaInterval(start: zero, end: two).validate(duration: one) }
    try MediaInterval(start: zero, end: one).validate(duration: one)
    #expect(throws: FileformError.self) {
        try MediaInterval(start: .init(ticks: 1, timescale: 2), end: .init(ticks: 2, timescale: 4)).validate()
    }
    for invalid in [MediaTime(ticks: -1, timescale: 1), MediaTime(ticks: 1, timescale: 0),
                    MediaTime(ticks: 1, timescale: -1)] {
        #expect(throws: FileformError.self) { try invalid.validate() }
        #expect(throws: FileformError.self) { try zero.isBefore(invalid) }
    }
}

@Test func rationalTimeComparisonDoesNotOverflowOrRoundThroughDouble() throws {
    let earlier = MediaTime(ticks: Int64.max - 1, timescale: Int32.max)
    let later = MediaTime(ticks: Int64.max, timescale: Int32.max)
    #expect(try earlier.isBefore(later))
    #expect(try !later.isBefore(earlier))
    let smaller = MediaTime(ticks: Int64.max, timescale: Int32.max)
    let larger = MediaTime(ticks: Int64.max - 1, timescale: Int32.max - 1)
    #expect(try smaller.isBefore(larger))
    #expect(try !larger.isBefore(smaller))
    let whole = MediaTime(ticks: Int64.max / 2, timescale: 1)
    let equivalent = MediaTime(ticks: (Int64.max / 2) * 2, timescale: 2)
    #expect(try !whole.isBefore(equivalent))
    #expect(try !equivalent.isBefore(whole))
}

@Test func cropRejectsOverflowAndOutOfBoundsCoordinates() throws {
    let invalid = [PixelCrop(x: Int.max, y: 0, width: 1, height: 1),
                   PixelCrop(x: 0, y: Int.max, width: 1, height: 1),
                   PixelCrop(x: -1, y: 0, width: 1, height: 1),
                   PixelCrop(x: 0, y: -1, width: 1, height: 1),
                   PixelCrop(x: 0, y: 0, width: 0, height: 1),
                   PixelCrop(x: 0, y: 0, width: 1, height: -1)]
    for crop in invalid { #expect(throws: FileformError.self) { try crop.validate() } }
    let crop = PixelCrop(x: 10, y: 20, width: 30, height: 40)
    try crop.validate(sourceWidth: 40, sourceHeight: 60)
    #expect(throws: FileformError.self) { try crop.validate(sourceWidth: 39, sourceHeight: 60) }
    #expect(throws: FileformError.self) { try crop.validate(sourceWidth: 40, sourceHeight: 59) }
}

@Test func operationRejectsIncompatibleCardinalityAndFormat() throws {
    #expect(throws: FileformError.self) { try contractRequest(.pdfSplit(groups: [[contractPage]])) }
    #expect(throws: FileformError.self) { try contractRequest(.pdfComposition(pages: [contractPage]), cardinality: .directory) }
    #expect(throws: FileformError.self) { try contractRequest(.pdfComposition(pages: [contractPage]), format: .png) }
    #expect(throws: FileformError.self) { try contractRequest(.pdfSplit(groups: [[contractPage]]), format: .png, cardinality: .directory) }
    #expect(throws: FileformError.self) {
        try contractRequest(.imageCrop(rectangle: .init(x: 0, y: 0, width: 1, height: 1), conversion: .init()))
    }
    let interval = MediaInterval(start: .init(ticks: 0, timescale: 1), end: .init(ticks: 1, timescale: 1))
    #expect(throws: FileformError.self) { try contractRequest(.mediaTrim(interval: interval, mode: .exact, audioStream: nil)) }
    #expect(throws: FileformError.self) { try contractRequest(.mediaTrim(interval: interval, mode: .exact, audioStream: -1), format: .mp4) }
    #expect(throws: FileformError.self) { try contractRequest(.conversion(.init()), assets: []) }
    #expect(throws: FileformError.self) { try contractRequest(.conversion(.init()), assets: [contractAsset, contractAsset]) }
}

@Test func conversionPoliciesRejectInvalidValues() throws {
    let invalid = [ConversionOptions(quality: .nan), ConversionOptions(quality: .infinity),
                   ConversionOptions(quality: 0), ConversionOptions(quality: 1.01),
                   ConversionOptions(minimumQuality: .nan), ConversionOptions(minimumQuality: 0),
                   ConversionOptions(quality: 0.5, minimumQuality: 0.6),
                   ConversionOptions(maxDimension: 0), ConversionOptions(maxDimension: 32769),
                   ConversionOptions(minimumVideoBitrate: 49_999), ConversionOptions(minimumVideoBitrate: 100_000_001),
                   ConversionOptions(pageNumber: 0), ConversionOptions(pageNumber: -1),
                   ConversionOptions(maximumBytes: 1)]
    for options in invalid {
        #expect(throws: FileformError.self) { try contractRequest(.conversion(.init(options: options))) }
    }
    let invalidByteLimits: [Int64?] = [nil, 0, -1]
    for bytes in invalidByteLimits {
        #expect(throws: FileformError.self) {
            try contractRequest(.conversion(.init(goal: .fit, options: .init(maximumBytes: bytes))))
        }
    }
    _ = try contractRequest(.conversion(.init(goal: .fit, options: .init(maximumBytes: 1))))
}

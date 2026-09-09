// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Stable operation identifiers. Declaration does not imply backend availability.
public enum OperationID: String, Codable, Sendable {
    case conversion = "file.convert", pdfComposition = "pdf.compose", pdfSplit = "pdf.split"
    case mediaTrim = "media.trim", imageCrop = "image.crop", fetch = "link.fetch"
}
public enum OutputCardinality: String, Codable, Sendable { case file, directory }
public enum FidelityPolicy: String, Codable, Sendable { case allowDeclaredLosses, requireLossless }
public enum ColorPolicy: String, Codable, Sendable { case convertToSRGB, preserve }
public enum MetadataPolicy: String, Codable, Sendable { case removeDescriptive, preserve }
public enum TrimMode: String, Codable, Sendable { case exact, copy }

public struct AssetReference: Codable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public init(id: String, url: URL) { self.id = id; self.url = url }
}

/// Coordinates in pixels after source orientation has been applied; origin top-left.
public struct PixelCrop: Codable, Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func validate(sourceWidth: Int? = nil, sourceHeight: Int? = nil) throws {
        guard x >= 0, y >= 0, width > 0, height > 0,
              !x.addingReportingOverflow(width).overflow, !y.addingReportingOverflow(height).overflow else {
            throw FileformError(.invalidRequest, "Crop coordinates must describe a nonempty pixel rectangle.")
        }
        if let sourceWidth, x + width > sourceWidth { throw FileformError(.invalidRequest, "Crop exceeds image width.") }
        if let sourceHeight, y + height > sourceHeight { throw FileformError(.invalidRequest, "Crop exceeds image height.") }
    }
}

/// Nonnegative rational time. Cross-products use 128-bit intermediates, not Double.
public struct MediaTime: Codable, Equatable, Sendable {
    public let ticks: Int64
    public let timescale: Int32
    public init(ticks: Int64, timescale: Int32) { self.ticks = ticks; self.timescale = timescale }
    public func validate() throws {
        guard ticks >= 0, timescale > 0 else { throw FileformError(.invalidRequest, "Time requires nonnegative ticks and a positive timescale.") }
    }
    public func isBefore(_ other: MediaTime) throws -> Bool {
        try validate(); try other.validate()
        let lhs = ticks.multipliedFullWidth(by: Int64(other.timescale))
        let rhs = other.ticks.multipliedFullWidth(by: Int64(timescale))
        return lhs.high == rhs.high ? lhs.low < rhs.low : lhs.high < rhs.high
    }
}
public struct MediaInterval: Codable, Equatable, Sendable {
    public let start: MediaTime, end: MediaTime
    public init(start: MediaTime, end: MediaTime) { self.start = start; self.end = end }
    public func validate(duration: MediaTime? = nil) throws {
        guard try start.isBefore(end) else { throw FileformError(.invalidRequest, "Choose a nonempty half-open time interval [start, end).") }
        if let duration, try duration.isBefore(end) { throw FileformError(.invalidRequest, "The selected interval exceeds the recording duration.") }
    }
}
public struct PageReference: Codable, Equatable, Sendable {
    public let sourceID: String
    public let pageIndex: Int
    public let clockwiseRotation: Int
    public init(sourceID: String, pageIndex: Int, clockwiseRotation: Int = 0) {
        self.sourceID = sourceID; self.pageIndex = pageIndex; self.clockwiseRotation = clockwiseRotation
    }
}
public struct ConversionParameters: Codable, Equatable, Sendable {
    public let goal: ConversionGoal
    public let options: ConversionOptions
    public let color: ColorPolicy
    public let metadata: MetadataPolicy
    public init(goal: ConversionGoal = .convert, options: ConversionOptions = .init(),
                color: ColorPolicy = .convertToSRGB, metadata: MetadataPolicy = .removeDescriptive) {
        self.goal = goal; self.options = options; self.color = color; self.metadata = metadata
    }
}

/// Codable's single-case keyed representation is the v1 tagged payload encoding.
public enum TransformationOperation: Codable, Equatable, Sendable {
    case conversion(ConversionParameters)
    case pdfComposition(pages: [PageReference])
    /// Each nonempty group is one output PDF; duplicates and order are intentional.
    case pdfSplit(groups: [[PageReference]])
    case mediaTrim(interval: MediaInterval, mode: TrimMode, audioStream: Int?, muteAudio: Bool = false)
    case imageCrop(rectangle: PixelCrop, conversion: ConversionParameters)
    /// Explicit invocation authorizes this bounded source request; never local uploads.
    case fetch(url: URL, maximumBytes: Int64)

    // Decode existing v1 records without a mute field as automatic audio
    // selection. Never reinterpret nil audioStream as permission to drop audio.
    private enum OperationKey: String, CodingKey { case conversion, pdfComposition, pdfSplit, mediaTrim, mediaTrimMuted, imageCrop, fetch }
    private enum ParameterKey: String, CodingKey { case _0, pages, groups, interval, mode, audioStream, muteAudio, rectangle, conversion, url, maximumBytes }
    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: OperationKey.self)
        guard root.allKeys.count == 1, let key = root.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected one known transformation operation."))
        }
        let value = try root.nestedContainer(keyedBy: ParameterKey.self, forKey: key)
        switch key {
        case .conversion: self = .conversion(try value.decode(ConversionParameters.self, forKey: ._0))
        case .pdfComposition: self = .pdfComposition(pages: try value.decode([PageReference].self, forKey: .pages))
        case .pdfSplit: self = .pdfSplit(groups: try value.decode([[PageReference]].self, forKey: .groups))
        case .mediaTrim, .mediaTrimMuted:
            let explicitMute = value.contains(.muteAudio) ? try value.decode(Bool.self, forKey: .muteAudio) : nil
            let muted = key == .mediaTrimMuted
            guard explicitMute == nil || explicitMute == muted else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Mute policy conflicts with its wire operation tag."))
            }
            self = .mediaTrim(interval: try value.decode(MediaInterval.self, forKey: .interval),
                              mode: try value.decode(TrimMode.self, forKey: .mode),
                              audioStream: try value.decodeIfPresent(Int.self, forKey: .audioStream),
                              muteAudio: muted)
        case .imageCrop:
            self = .imageCrop(rectangle: try value.decode(PixelCrop.self, forKey: .rectangle),
                              conversion: try value.decode(ConversionParameters.self, forKey: .conversion))
        case .fetch:
            self = .fetch(url: try value.decode(URL.self, forKey: .url), maximumBytes: try value.decode(Int64.self, forKey: .maximumBytes))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: OperationKey.self)
        switch self {
        case .conversion(let conversion):
            var value = root.nestedContainer(keyedBy: ParameterKey.self, forKey: .conversion)
            try value.encode(conversion, forKey: ._0)
        case .pdfComposition(let pages):
            var value = root.nestedContainer(keyedBy: ParameterKey.self, forKey: .pdfComposition)
            try value.encode(pages, forKey: .pages)
        case .pdfSplit(let groups):
            var value = root.nestedContainer(keyedBy: ParameterKey.self, forKey: .pdfSplit)
            try value.encode(groups, forKey: .groups)
        case .mediaTrim(let interval, let mode, let audio, let muted):
            // Older v1 clients must reject muted work rather than silently
            // retaining audio by ignoring an unknown Boolean field.
            var value = root.nestedContainer(keyedBy: ParameterKey.self, forKey: muted ? .mediaTrimMuted : .mediaTrim)
            try value.encode(interval, forKey: .interval)
            try value.encode(mode, forKey: .mode)
            try value.encodeIfPresent(audio, forKey: .audioStream)
        case .imageCrop(let rectangle, let conversion):
            var value = root.nestedContainer(keyedBy: ParameterKey.self, forKey: .imageCrop)
            try value.encode(rectangle, forKey: .rectangle)
            try value.encode(conversion, forKey: .conversion)
        case .fetch(let url, let bytes):
            var value = root.nestedContainer(keyedBy: ParameterKey.self, forKey: .fetch)
            try value.encode(url, forKey: .url)
            try value.encode(bytes, forKey: .maximumBytes)
        }
    }

    public var id: OperationID {
        switch self {
        case .conversion: .conversion; case .pdfComposition: .pdfComposition; case .pdfSplit: .pdfSplit
        case .mediaTrim: .mediaTrim; case .imageCrop: .imageCrop; case .fetch: .fetch
        }
    }
    public var cardinality: OutputCardinality { if case .pdfSplit = self { .directory } else { .file } }
}
public struct OutputSpecification: Codable, Equatable, Sendable {
    public let destination: URL
    public let format: OutputFormat
    public let cardinality: OutputCardinality
    public init(destination: URL, format: OutputFormat, cardinality: OutputCardinality = .file) {
        self.destination = destination; self.format = format; self.cardinality = cardinality
    }
}

public struct TransformationRequest: Codable, Sendable {
    public let schemaVersion: Int
    public let assets: [AssetReference]
    public let operation: TransformationOperation
    public let output: OutputSpecification
    public let fidelity: FidelityPolicy
    public let collisionPolicy: CollisionPolicy
    public init(assets: [AssetReference], operation: TransformationOperation, output: OutputSpecification,
                fidelity: FidelityPolicy = .allowDeclaredLosses, collisionPolicy: CollisionPolicy = .fail) throws {
        self.schemaVersion = 1; self.assets = assets; self.operation = operation; self.output = output
        self.fidelity = fidelity; self.collisionPolicy = collisionPolicy
        try validate()
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw FileformError(.invalidRequest, "Unsupported transformation schema version.") }
        guard assets.count <= 10_000, Set(assets.map(\.id)).count == assets.count,
              assets.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && !$0.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && $0.url.isFileURL }),
              output.destination.isFileURL, output.cardinality == operation.cardinality else {
            throw FileformError(.invalidRequest, "Invalid asset bindings or output cardinality.")
        }
        let destination = output.destination.standardizedFileURL.resolvingSymlinksInPath()
        guard assets.allSatisfy({ $0.url.standardizedFileURL.resolvingSymlinksInPath() != destination }) else {
            throw FileformError(.invalidRequest, "The destination cannot be a source file.")
        }
        switch operation {
        case .conversion(let parameters): try singleAsset(); try validateConversion(parameters)
        case .imageCrop(let rectangle, let parameters):
            try singleAsset(); try rectangle.validate(); try validateConversion(parameters)
            guard output.format.family == .image else { throw FileformError(.invalidRequest, "Image crop requires an image output.") }
        case .pdfComposition(let pages): try validatePages(pages)
        case .pdfSplit(let groups):
            guard !groups.isEmpty, groups.count <= 10_000, groups.reduce(0, { $0 + $1.count }) <= 100_000 else {
                throw FileformError(.invalidRequest, "Choose between 1 and 10000 split groups, with at most 100000 pages.")
            }
            for pages in groups { try validatePages(pages) }
        case .mediaTrim(let interval, _, let audioStream, let muteAudio):
            try singleAsset(); try interval.validate()
            guard output.format.family == .media, audioStream.map({ $0 >= 0 }) ?? true,
                  !muteAudio || ([.mp4, .mov].contains(output.format) && audioStream == nil) else {
                throw FileformError(.invalidRequest, "Trim requires a media output and a nonnegative stream index. Muting requires video output and cannot select an audio stream.")
            }
        case .fetch(let url, let maximumBytes):
            guard assets.isEmpty, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil, maximumBytes > 0 else {
                throw FileformError(.invalidRequest, "Link acquisition requires an HTTP(S) URL without credentials, no local inputs and a positive byte limit.")
            }
        }
    }
    private func singleAsset() throws {
        guard assets.count == 1 else { throw FileformError(.invalidRequest, "This operation needs exactly one local input.") }
    }
    private func validatePages(_ pages: [PageReference]) throws {
        let ids = Set(assets.map(\.id))
        guard !assets.isEmpty, !pages.isEmpty, pages.count <= 100_000, output.format == .pdf,
              pages.allSatisfy({ ids.contains($0.sourceID) && $0.pageIndex >= 0 && [0, 90, 180, 270].contains($0.clockwiseRotation) }) else {
            throw FileformError(.invalidRequest, "PDF pages need known source IDs, zero-based indices and quarter-turn rotations.")
        }
    }
    private func validateConversion(_ parameters: ConversionParameters) throws {
        let o = parameters.options
        guard o.quality.isFinite, o.minimumQuality.isFinite, (0.05...1).contains(o.quality),
              (0.05...o.quality).contains(o.minimumQuality),
              o.maxDimension.map({ (1...32768).contains($0) }) ?? true,
              o.pageNumber.map({ $0 > 0 }) ?? true,
              (50_000...100_000_000).contains(o.minimumVideoBitrate),
              parameters.goal == .fit ? (o.maximumBytes.map({ $0 > 0 }) ?? false) : o.maximumBytes == nil else {
            throw FileformError(.invalidRequest, "Invalid conversion quality, dimensions, page or size constraints.")
        }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, assets, operation, output, fidelity, collisionPolicy }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        assets = try c.decode([AssetReference].self, forKey: .assets)
        operation = try c.decode(TransformationOperation.self, forKey: .operation)
        output = try c.decode(OutputSpecification.self, forKey: .output)
        fidelity = try c.decode(FidelityPolicy.self, forKey: .fidelity)
        collisionPolicy = try c.decode(CollisionPolicy.self, forKey: .collisionPolicy)
        try validate()
    }
}

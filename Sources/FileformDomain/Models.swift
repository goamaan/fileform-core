// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum FileFamily: String, Codable, Sendable { case image, media, pdf, table, text }

public enum OutputFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case jpeg, png, tiff, heic, avif, webp
    case mp4, mov, m4a, wav, flac, mp3
    case pdf, txt, markdown, csv, tsv, json
    public var id: String { rawValue }
    public var fileExtension: String {
        switch self { case .jpeg: "jpg"; case .tiff: "tiff"; case .markdown: "md"; default: rawValue }
    }
    public var title: String {
        switch self { case .jpeg: "JPEG"; case .tiff: "TIFF"; case .markdown: "Markdown"; default: rawValue.uppercased() }
    }
    public var family: FileFamily {
        switch self {
        case .jpeg, .png, .tiff, .heic, .avif, .webp: .image
        case .mp4, .mov, .m4a, .wav, .flac, .mp3: .media
        case .pdf: .pdf
        case .csv, .tsv, .json: .table
        case .txt, .markdown: .text
        }
    }
    public var imageType: String? {
        switch self {
        case .jpeg: "public.jpeg"; case .png: "public.png"; case .tiff: "public.tiff"
        case .heic: "public.heic"; case .avif: "public.avif"; case .webp: "org.webmproject.webp"
        default: nil
        }
    }
    public var supportsAlpha: Bool { [.png, .tiff, .webp, .avif, .heic].contains(self) }
    public var isLossyImage: Bool { [.jpeg, .heic, .avif, .webp].contains(self) }
}

public enum ConversionGoal: String, CaseIterable, Codable, Sendable, Identifiable {
    case convert, compress, fit
    public var id: String { rawValue }
    public var title: String {
        switch self { case .convert: "Convert format"; case .compress: "Make smaller"; case .fit: "Fit under a size" }
    }
}
public enum CollisionPolicy: String, Codable, Sendable { case fail, rename }
public enum AlphaBackground: String, CaseIterable, Codable, Sendable { case white, black }

public struct ConversionOptions: Codable, Equatable, Sendable {
    public var quality: Double
    public var minimumQuality: Double
    public var maxDimension: Int?
    public var maximumBytes: Int64?
    public var background: AlphaBackground?
    public var minimumVideoBitrate: Int
    public var pageNumber: Int?
    public init(quality: Double = 0.82, minimumQuality: Double = 0.35,
                maxDimension: Int? = nil, maximumBytes: Int64? = nil,
                background: AlphaBackground? = nil, minimumVideoBitrate: Int = 150_000, pageNumber: Int? = nil) {
        self.quality = quality; self.minimumQuality = minimumQuality
        self.maxDimension = maxDimension; self.maximumBytes = maximumBytes; self.background = background
        self.minimumVideoBitrate = minimumVideoBitrate
        self.pageNumber = pageNumber
    }
}

public struct ConversionRequest: Codable, Sendable {
    public let input: URL
    public let destination: URL
    public let format: OutputFormat
    public let goal: ConversionGoal
    public let options: ConversionOptions
    public let collisionPolicy: CollisionPolicy
    public init(input: URL, destination: URL, format: OutputFormat, goal: ConversionGoal = .convert,
                options: ConversionOptions = .init(), collisionPolicy: CollisionPolicy = .fail) {
        self.input = input; self.destination = destination; self.format = format
        self.goal = goal; self.options = options; self.collisionPolicy = collisionPolicy
    }
}

public struct FileIdentity: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public let bytes: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public init(device: Int32, inode: UInt64, bytes: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64) {
        self.device = device; self.inode = inode; self.bytes = bytes
        self.modifiedSeconds = modifiedSeconds; self.modifiedNanoseconds = modifiedNanoseconds
    }
}

public struct Inspection: Codable, Sendable {
    public let input: URL
    public let identity: FileIdentity
    public let family: FileFamily
    public let detectedType: String
    public var width: Int?
    public var height: Int?
    public var frameCount: Int?
    public var hasAlpha: Bool?
    public var bitDepth: Int?
    public var orientation: Int?
    public var duration: Double?
    public var videoCodec: String?
    public var audioCodec: String?
    public var audioStreams: Int?
    public var audioSampleFormat: String?
    public var audioBitDepth: Int?
    public var pageCount: Int?
    public var tableRows: Int?
    public var tableColumns: Int?
    public var warnings: [String]
    public init(input: URL, identity: FileIdentity, family: FileFamily, detectedType: String,
                width: Int? = nil, height: Int? = nil, frameCount: Int? = nil, hasAlpha: Bool? = nil,
                bitDepth: Int? = nil, orientation: Int? = nil, duration: Double? = nil,
                videoCodec: String? = nil, audioCodec: String? = nil, audioStreams: Int? = nil,
                pageCount: Int? = nil, tableRows: Int? = nil, tableColumns: Int? = nil,
                audioSampleFormat: String? = nil, audioBitDepth: Int? = nil, warnings: [String] = []) {
        self.input = input; self.identity = identity; self.family = family; self.detectedType = detectedType
        self.width = width; self.height = height; self.frameCount = frameCount; self.hasAlpha = hasAlpha
        self.bitDepth = bitDepth; self.orientation = orientation; self.duration = duration
        self.videoCodec = videoCodec; self.audioCodec = audioCodec; self.audioStreams = audioStreams
        self.pageCount = pageCount; self.warnings = warnings
        self.tableRows = tableRows; self.tableColumns = tableColumns
        self.audioSampleFormat = audioSampleFormat; self.audioBitDepth = audioBitDepth
    }
}

public struct Capability: Codable, Sendable, Identifiable {
    public let format: OutputFormat
    public let goals: [ConversionGoal]
    public let engine: String
    public let available: Bool
    public let limitation: String?
    public var id: String { "\(engine):\(format.rawValue)" }
    public init(format: OutputFormat, goals: [ConversionGoal], engine: String, available: Bool, limitation: String? = nil) {
        self.format = format; self.goals = goals; self.engine = engine; self.available = available; self.limitation = limitation
    }
}

public struct ConversionPlan: Codable, Sendable {
    public let schemaVersion: Int
    public let request: ConversionRequest
    public let inspection: Inspection
    public let engine: String
    public let warnings: [String]
    public init(request: ConversionRequest, inspection: Inspection, engine: String, warnings: [String]) {
        self.schemaVersion = 1; self.request = request; self.inspection = inspection; self.engine = engine; self.warnings = warnings
    }
}

public enum JobPhase: String, Codable, Sendable { case inspecting, preparing, encoding, verifying, saving }
public struct ProgressEvent: Codable, Sendable {
    public let phase: JobPhase
    public let fraction: Double?
    public init(_ phase: JobPhase, fraction: Double? = nil) { self.phase = phase; self.fraction = fraction }
}
public enum ResultStatus: String, Codable, Sendable { case succeeded, alreadySatisfied = "already_satisfied", notSmaller = "not_smaller" }
public struct VerifiedResult: Codable, Sendable {
    public let schemaVersion: Int
    public let status: ResultStatus
    public let input: URL
    public let output: URL?
    public let inputBytes: Int64
    public let outputBytes: Int64?
    public let format: OutputFormat
    public let warnings: [String]
    public let attempts: Int
    public init(status: ResultStatus, input: URL, output: URL?, inputBytes: Int64, outputBytes: Int64?,
                format: OutputFormat, warnings: [String], attempts: Int) {
        self.schemaVersion = 1; self.status = status; self.input = input; self.output = output; self.inputBytes = inputBytes
        self.outputBytes = outputBytes; self.format = format; self.warnings = warnings; self.attempts = attempts
    }
}

public struct FileformError: Error, Codable, Sendable, LocalizedError {
    public enum Code: String, Codable, Sendable {
        case invalidRequest = "invalid_request", unsupported, inputChanged = "input_changed"
        case ioFailure = "io_failure", destinationExists = "destination_exists", targetUnmet = "target_unmet"
        case engineUnavailable = "engine_unavailable", engineFailed = "engine_failed", verificationFailed = "verification_failed"
        case resourceLimit = "resource_limit", cancelled
    }
    public let code: Code
    public let message: String
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
    public var exitCode: Int32 {
        switch code {
        case .invalidRequest: 2; case .unsupported, .engineUnavailable: 3; case .targetUnmet: 4
        case .ioFailure, .destinationExists, .inputChanged: 5
        case .engineFailed, .verificationFailed, .resourceLimit: 6; case .cancelled: 130
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Wire values do not open descriptors or grant sandbox access. The launcher must
/// validate the handshake and descriptor ownership before dispatching work.
public enum WorkerProtocol {
    public static let version = 1
    public static let maximumFrameBytes = 1_048_576
    public static let maximumPreviewDimension = 4_096
}

public enum WorkerProtocolError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidRequest
    case invalidFrameLimit
    case emptyFrame
    case oversizedFrame
    case malformedMessage
    case truncatedFrame
    case decoderClosed
}

public struct WorkerAssetHandle: Codable, Equatable, Sendable {
    public let assetID: String
    public let descriptor: Int32
    public init(assetID: String, descriptor: Int32) {
        self.assetID = assetID; self.descriptor = descriptor
    }
    fileprivate func validate() throws {
        guard !assetID.isEmpty, assetID.utf8.count <= 128,
              !assetID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              descriptor >= 3 else { throw WorkerProtocolError.invalidRequest }
    }
}

public enum WorkerOperation: Codable, Equatable, Sendable {
    case handshake
    case inspect(asset: WorkerAssetHandle)
    /// The output descriptor must be a distinct, inherited, job-owned writable
    /// scratch file. It is never a final destination. Page indices are zero-based.
    case preview(asset: WorkerAssetHandle, outputDescriptor: Int32, maximumDimension: Int, pageIndex: Int?)

    fileprivate func validate() throws {
        switch self {
        case .handshake: break
        case .inspect(let asset): try asset.validate()
        case .preview(let asset, let output, let dimension, let page):
            try asset.validate()
            guard output >= 3, output != asset.descriptor,
                  (1...WorkerProtocol.maximumPreviewDimension).contains(dimension),
                  page.map({ $0 >= 0 }) ?? true else { throw WorkerProtocolError.invalidRequest }
        }
    }
}

public struct WorkerRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let operation: WorkerOperation
    public init(id: UUID = UUID(), operation: WorkerOperation) throws {
        try operation.validate()
        version = WorkerProtocol.version; self.id = id; self.operation = operation
    }
    private enum CodingKeys: String, CodingKey { case version, id, operation }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == WorkerProtocol.version else { throw WorkerProtocolError.unsupportedVersion(version) }
        id = try values.decode(UUID.self, forKey: .id)
        operation = try values.decode(WorkerOperation.self, forKey: .operation)
        try operation.validate()
    }
}

public struct WorkerPreviewArtifact: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable { case png }
    public let bytes: Int64
    public let width: Int
    public let height: Int
    public let format: Format
    public init(bytes: Int64, width: Int, height: Int) {
        self.bytes = bytes; self.width = width; self.height = height; format = .png
    }
    fileprivate func validate() throws {
        guard bytes > 0, (1...WorkerProtocol.maximumPreviewDimension).contains(width),
              (1...WorkerProtocol.maximumPreviewDimension).contains(height) else {
            throw WorkerProtocolError.invalidRequest
        }
    }
}

/// No raw parser messages, paths, credentials, executable names or flags cross
/// this failure channel. The coordinator supplies user-facing explanations.
public enum WorkerFailureCode: String, Codable, Sendable {
    case unsupportedInput, invalidInput, permissionDenied, resourceLimit, cancelled, internalFailure
}

/// Path-free inspection transport. Warning strings must be curated; never copy
/// raw parser diagnostics into this payload. The coordinator owns origin URLs.
public struct WorkerInspectionResult: Codable, Sendable {
    public let assetID: String
    public let identity: FileIdentity
    public let family: FileFamily
    public let detectedType: String
    public let width: Int?
    public let height: Int?
    public let frameCount: Int?
    public let hasAlpha: Bool?
    public let bitDepth: Int?
    public let orientation: Int?
    public let duration: Double?
    public let videoCodec: String?
    public let audioCodec: String?
    public let audioStreams: Int?
    public let audioSampleFormat: String?
    public let audioBitDepth: Int?
    public let pageCount: Int?
    public let tableRows: Int?
    public let tableColumns: Int?
    public let warnings: [String]
    public init(assetID: String, inspection: Inspection) throws {
        try WorkerAssetHandle(assetID: assetID, descriptor: 3).validate()
        self.assetID = assetID
        identity = inspection.identity
        family = inspection.family
        detectedType = inspection.detectedType
        width = inspection.width
        height = inspection.height
        frameCount = inspection.frameCount
        hasAlpha = inspection.hasAlpha
        bitDepth = inspection.bitDepth
        orientation = inspection.orientation
        duration = inspection.duration
        videoCodec = inspection.videoCodec
        audioCodec = inspection.audioCodec
        audioStreams = inspection.audioStreams
        audioSampleFormat = inspection.audioSampleFormat
        audioBitDepth = inspection.audioBitDepth
        pageCount = inspection.pageCount
        tableRows = inspection.tableRows
        tableColumns = inspection.tableColumns
        warnings = inspection.warnings
    }

    /// Call only after matching assetID to the outstanding request.
    public func inspection(rebindingTo input: URL) -> Inspection {
        Inspection(input: input, identity: identity,
                   family: family,
                   detectedType: detectedType,
                   width: width,
                   height: height,
                   frameCount: frameCount,
                   hasAlpha: hasAlpha,
                   bitDepth: bitDepth,
                   orientation: orientation,
                   duration: duration,
                   videoCodec: videoCodec,
                   audioCodec: audioCodec,
                   audioStreams: audioStreams,
                   pageCount: pageCount,
                   tableRows: tableRows,
                   tableColumns: tableColumns,
                   audioSampleFormat: audioSampleFormat,
                   audioBitDepth: audioBitDepth,
                   warnings: warnings)
    }
}

public enum WorkerResponsePayload: Codable, Sendable {
    case handshake(protocolVersion: Int)
    case inspection(WorkerInspectionResult)
    case preview(WorkerPreviewArtifact)
    case failure(WorkerFailureCode)

    fileprivate func validate() throws {
        switch self {
        case .handshake(let version):
            guard version == WorkerProtocol.version else { throw WorkerProtocolError.unsupportedVersion(version) }
        case .preview(let artifact): try artifact.validate()
        case .inspection(let result):
            try WorkerAssetHandle(assetID: result.assetID, descriptor: 3).validate()
        case .failure: break
        }
    }
}

public struct WorkerResponse: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let payload: WorkerResponsePayload
    public init(id: UUID, payload: WorkerResponsePayload) throws {
        try payload.validate()
        version = WorkerProtocol.version; self.id = id; self.payload = payload
    }
    private enum CodingKeys: String, CodingKey { case version, id, payload }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == WorkerProtocol.version else { throw WorkerProtocolError.unsupportedVersion(version) }
        id = try values.decode(UUID.self, forKey: .id)
        payload = try values.decode(WorkerResponsePayload.self, forKey: .payload)
        try payload.validate()
    }
}

/// Four-byte unsigned network-order length followed by one UTF-8 JSON value.
public enum WorkerFrameCodec {
    public static func encode<Message: Encodable>(_ message: Message,
        maximumBytes: Int = WorkerProtocol.maximumFrameBytes) throws -> Data {
        try validateLimit(maximumBytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(message)
        guard !body.isEmpty else { throw WorkerProtocolError.emptyFrame }
        guard body.count <= maximumBytes else { throw WorkerProtocolError.oversizedFrame }
        let count = UInt32(body.count)
        var frame = Data([UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
                          UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
        frame.append(body)
        return frame
    }
    fileprivate static func validateLimit(_ value: Int) throws {
        guard value > 0, value <= Int(UInt32.max) else { throw WorkerProtocolError.invalidFrameLimit }
    }
}

/// Incremental parser: buffers at most four header bytes plus one bounded body.
/// Invalid input permanently closes this instance; create a new one for a new
/// pipe. Call finish() at EOF to distinguish a clean close from truncation.
/// Pipe reads should also be bounded by the caller; returned message arrays are
/// proportional to the number of complete frames in that caller-supplied chunk.
public struct WorkerFrameDecoder<Message: Decodable> {
    public let maximumBytes: Int
    private var header = Data()
    private var body = Data()
    private var expectedBytes: Int?
    private var closed = false
    public init(maximumBytes: Int = WorkerProtocol.maximumFrameBytes) throws {
        try WorkerFrameCodec.validateLimit(maximumBytes)
        self.maximumBytes = maximumBytes
    }
    public var bufferedByteCount: Int { header.count + body.count }

    public mutating func append(_ data: Data) throws -> [Message] {
        guard !closed else { throw WorkerProtocolError.decoderClosed }
        var messages: [Message] = []
        var offset = data.startIndex
        do {
            while offset < data.endIndex {
                if expectedBytes == nil {
                    let end = data.index(offset, offsetBy: min(4 - header.count, data.distance(from: offset, to: data.endIndex)))
                    header.append(contentsOf: data[offset..<end]); offset = end
                    guard header.count == 4 else { break }
                    let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard length > 0 else { throw WorkerProtocolError.emptyFrame }
                    guard UInt64(length) <= UInt64(maximumBytes) else { throw WorkerProtocolError.oversizedFrame }
                    expectedBytes = Int(length)
                    // Do not reserve capacity from an untrusted declared length.
                    header.removeAll(keepingCapacity: true)
                }
                guard let expectedBytes else { continue }
                let end = data.index(offset, offsetBy: min(expectedBytes - body.count, data.distance(from: offset, to: data.endIndex)))
                body.append(contentsOf: data[offset..<end]); offset = end
                if body.count == expectedBytes {
                    let message: Message
                    do { message = try JSONDecoder().decode(Message.self, from: body) }
                    catch let error as WorkerProtocolError { throw error }
                    catch { throw WorkerProtocolError.malformedMessage }
                    messages.append(message)
                    body = Data(); self.expectedBytes = nil
                }
            }
            return messages
        } catch {
            closed = true; header = Data(); body = Data(); expectedBytes = nil
            throw error
        }
    }

    public mutating func finish() throws {
        guard !closed else { throw WorkerProtocolError.decoderClosed }
        closed = true
        let incomplete = !header.isEmpty || expectedBytes != nil
        header = Data(); body = Data(); expectedBytes = nil
        if incomplete { throw WorkerProtocolError.truncatedFrame }
    }
}

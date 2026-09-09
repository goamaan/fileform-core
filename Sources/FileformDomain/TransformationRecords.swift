// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct InspectedAsset: Codable, Sendable {
    public let id: String
    public let inspection: Inspection
    public init(id: String, inspection: Inspection) { self.id = id; self.inspection = inspection }
}
public struct TransformationPlan: Codable, Sendable {
    public let schemaVersion: Int
    public let request: TransformationRequest
    public let inputs: [InspectedAsset]
    public let warnings: [String]
    public let mediaTrim: MediaTrimDetails?
    public let fetchSource: FetchSourceSnapshot?
    public init(request: TransformationRequest, inputs: [InspectedAsset], warnings: [String], mediaTrim: MediaTrimDetails? = nil, fetchSource: FetchSourceSnapshot? = nil) {
        schemaVersion = 1; self.request = request; self.inputs = inputs; self.warnings = warnings
        self.mediaTrim = mediaTrim; self.fetchSource = fetchSource
    }
}
public struct CommittedArtifact: Codable, Sendable {
    public let url: URL
    public let format: OutputFormat
    public let bytes: Int64
    public let sourceIDs: [String]
    public init(url: URL, format: OutputFormat, bytes: Int64, sourceIDs: [String]) {
        self.url = url; self.format = format; self.bytes = bytes; self.sourceIDs = sourceIDs
    }
}
public struct TransformationResult: Codable, Sendable {
    public let schemaVersion: Int
    public let operationID: OperationID
    public let status: ResultStatus
    public let artifacts: [CommittedArtifact]
    public let warnings: [String]
    public let attempts: Int
    public let mediaTrim: MediaTrimDetails?
    public let fetchReceipt: FetchReceipt?
    public init(operationID: OperationID, status: ResultStatus, artifacts: [CommittedArtifact], warnings: [String], attempts: Int,
                mediaTrim: MediaTrimDetails? = nil, fetchReceipt: FetchReceipt? = nil) {
        schemaVersion = 1; self.operationID = operationID; self.status = status
        self.artifacts = artifacts; self.warnings = warnings; self.attempts = attempts
        self.mediaTrim = mediaTrim; self.fetchReceipt = fetchReceipt
    }
}
public enum TransformationEventPayload: Codable, Sendable {
    case queued
    case progress(ProgressEvent)
    case completed(TransformationResult)
    case failed(FileformError)
}
public struct TransformationEvent: Codable, Sendable {
    public let jobID: UUID
    public let sequence: UInt64
    public let payload: TransformationEventPayload
    public init(jobID: UUID, sequence: UInt64, payload: TransformationEventPayload) {
        self.jobID = jobID; self.sequence = sequence; self.payload = payload
    }
}

/// Portable setup: source slots are rebound explicitly; no paths, bookmarks or secrets.
/// Link URLs are deliberately excluded, because query strings may carry credentials.
public struct TransformationRecipe: Codable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let revision: Int
    public let name: String
    public let assetSlots: [String]
    public let operation: TransformationOperation
    public let format: OutputFormat
    public let fidelity: FidelityPolicy
    public let collisionPolicy: CollisionPolicy
    public init(id: UUID = UUID(), revision: Int = 1, name: String, request: TransformationRequest) throws {
        try request.validate()
        schemaVersion = 1; self.id = id; self.revision = revision; self.name = name
        assetSlots = request.assets.map(\.id); operation = request.operation; format = request.output.format
        fidelity = request.fidelity; collisionPolicy = request.collisionPolicy
        try validate()
    }
    public func validate() throws {
        guard schemaVersion == 1, revision > 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 200, Set(assetSlots).count == assetSlots.count else {
            throw FileformError(.invalidRequest, "Invalid setup version, revision, name or source slots.")
        }
        if case .fetch = operation { throw FileformError(.unsupported, "Link URLs cannot be stored in portable setups.") }
        // Validate operation shape without storing real user paths in a setup.
        _ = try bindUnchecked(assets: assetSlots.enumerated().map { .init(id: $0.element, url: URL(fileURLWithPath: "/fileform-recipe/source-\($0.offset)")) },
                              destination: URL(fileURLWithPath: "/fileform-recipe/output"))
    }
    public func bind(assets: [AssetReference], destination: URL) throws -> TransformationRequest {
        try validate()
        return try bindUnchecked(assets: assets, destination: destination)
    }
    private func bindUnchecked(assets: [AssetReference], destination: URL) throws -> TransformationRequest {
        guard assets.map(\.id) == assetSlots else { throw FileformError(.invalidRequest, "Bind every setup source slot in its recorded order.") }
        return try .init(assets: assets, operation: operation,
                         output: .init(destination: destination, format: format, cardinality: operation.cardinality),
                         fidelity: fidelity, collisionPolicy: collisionPolicy)
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, revision, name, assetSlots, operation, format, fidelity, collisionPolicy }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); id = try c.decode(UUID.self, forKey: .id)
        revision = try c.decode(Int.self, forKey: .revision); name = try c.decode(String.self, forKey: .name)
        assetSlots = try c.decode([String].self, forKey: .assetSlots); operation = try c.decode(TransformationOperation.self, forKey: .operation)
        format = try c.decode(OutputFormat.self, forKey: .format); fidelity = try c.decode(FidelityPolicy.self, forKey: .fidelity)
        collisionPolicy = try c.decode(CollisionPolicy.self, forKey: .collisionPolicy)
        try validate()
    }
}

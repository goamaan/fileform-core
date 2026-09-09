// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Runtime inventory, not a release acceptance certificate. A selected request
/// still needs planning: options may require explicit alpha/page/loss choices.
public struct CapabilityInventory: Codable, Sendable {
    public let schemaVersion: Int
    public let engineVersion: String
    public let platformVersion: String
    public let inputFamily: FileFamily?
    public let routes: [OperationCapability]
    public init(engineVersion: String, platformVersion: String, inputFamily: FileFamily?, routes: [OperationCapability]) {
        schemaVersion = 1; self.engineVersion = engineVersion; self.platformVersion = platformVersion
        self.inputFamily = inputFamily; self.routes = routes
    }
}
public struct OperationCapability: Codable, Sendable, Identifiable {
    public let id: String
    public let operationID: OperationID
    public let inputFamilies: [FileFamily]
    public let outputFormat: OutputFormat
    public let goals: [ConversionGoal]
    public let cardinality: OutputCardinality
    public let backend: String
    public let backendVersion: String?
    public let available: Bool
    public let localProcessing: Bool
    public let limitation: String?
    public let verification: String
    public init(id: String, inputFamilies: [FileFamily], capability: Capability, backendVersion: String?, verification: String,
                operationID: OperationID = .conversion, cardinality: OutputCardinality = .file, localProcessing: Bool = true) {
        self.id = id; self.operationID = operationID; self.inputFamilies = inputFamilies
        outputFormat = capability.format; goals = capability.goals; self.cardinality = cardinality
        backend = capability.engine; self.backendVersion = backendVersion; available = capability.available
        self.localProcessing = localProcessing; limitation = capability.limitation; self.verification = verification
    }
}

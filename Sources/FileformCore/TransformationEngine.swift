// SPDX-License-Identifier: Apache-2.0
import Foundation
import FileformDomain

public extension TransformationRequest {
    init(legacy: ConversionRequest) throws {
        try self.init(assets: [.init(id: "source", url: legacy.input)],
                      operation: .conversion(.init(goal: legacy.goal, options: legacy.options)),
                      output: .init(destination: legacy.destination, format: legacy.format), collisionPolicy: legacy.collisionPolicy)
    }
    func legacyConversion() throws -> ConversionRequest {
        try validate()
        guard case .conversion(let parameters) = operation else {
            throw FileformError(.unsupported, "This operation has a request schema but no installed execution adapter yet.")
        }
        guard parameters.color == .convertToSRGB, parameters.metadata == .removeDescriptive,
              fidelity == .allowDeclaredLosses else {
            throw FileformError(.unsupported, "The legacy converter cannot guarantee the requested color, metadata or lossless policy.")
        }
        return .init(input: assets[0].url, destination: output.destination, format: output.format,
                     goal: parameters.goal, options: parameters.options, collisionPolicy: collisionPolicy)
    }
}

public extension ConversionEngine {
    func plan(_ request: TransformationRequest) async throws -> TransformationPlan {
        let legacy = try request.legacyConversion()
        let plan = try await self.plan(legacy)
        try FileSafety.rejectSourceAliases(destination: request.output.destination, inputs: [plan.inspection])
        return .init(request: request, inputs: [.init(id: request.assets[0].id, inspection: plan.inspection)], warnings: plan.warnings)
    }
    func run(_ plan: TransformationPlan,
             progress: @escaping @Sendable (ProgressEvent) -> Void = { _ in }) async throws -> TransformationResult {
        guard plan.schemaVersion == 1 else { throw FileformError(.invalidRequest, "Unsupported transformation plan version.") }
        let request = try plan.request.legacyConversion()
        guard plan.inputs.count == 1, plan.inputs[0].id == plan.request.assets[0].id,
              plan.inputs[0].inspection.input == request.input.standardizedFileURL else {
            throw FileformError(.invalidRequest, "The plan does not match its source bindings.")
        }
        try FileSafety.verifyUnchanged(plan.inputs[0].inspection)
        try FileSafety.rejectSourceAliases(destination: request.destination, inputs: plan.inputs.map(\.inspection))
        // Legacy run re-inspects and revalidates; serialized warnings never select a backend.
        let legacy = ConversionPlan(request: request, inspection: plan.inputs[0].inspection, engine: "", warnings: [])
        let result = try await run(legacy, progress: progress)
        let artifacts: [CommittedArtifact]
        if let output = result.output, let bytes = result.outputBytes {
            artifacts = [.init(url: output, format: result.format, bytes: bytes, sourceIDs: plan.request.assets.map(\.id))]
        } else { artifacts = [] }
        return .init(operationID: plan.request.operation.id, status: result.status, artifacts: artifacts,
                     warnings: result.warnings, attempts: result.attempts)
    }
}

extension FileSafety {
    static func rejectSourceAliases(destination: URL, inputs: [Inspection]) throws {
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let existing = try? identity(target)
        for input in inputs {
            guard target != input.input.standardizedFileURL.resolvingSymlinksInPath(),
                  existing.map({ $0.device != input.identity.device || $0.inode != input.identity.inode }) ?? true else {
                throw FileformError(.invalidRequest, "The destination is an alias of a source file. Choose another output.")
            }
        }
    }
}

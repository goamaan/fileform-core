// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import FileformDomain
import FileformCore

private enum RuntimeTestFailure: Error { case timedOut }

private func collectedEvents(_ job: TransformationJob) async throws -> [TransformationEvent] {
    try await withThrowingTaskGroup(of: [TransformationEvent].self) { group in
        group.addTask {
            var events: [TransformationEvent] = []
            for await event in job.events { events.append(event) }
            return events
        }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            throw RuntimeTestFailure.timedOut
        }
        defer { group.cancelAll() }
        return try #require(await group.next())
    }
}

private func isTerminal(_ event: TransformationEvent) -> Bool {
    switch event.payload { case .completed, .failed: true; default: false }
}

private func expectEventContract(_ events: [TransformationEvent], jobID: UUID) throws {
    #expect(!events.isEmpty)
    #expect(events.allSatisfy { $0.jobID == jobID })
    #expect(events.map(\.sequence) == (0..<events.count).map(UInt64.init))
    #expect(events.filter(isTerminal).count == 1)
    let last = try #require(events.last)
    #expect(isTerminal(last))
    guard case .queued = events.first?.payload else { Issue.record("First event must be queued"); return }
}

@Test func runtimeSuccessfulJobHasOrderedEventsAndExactlyOneTerminal() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let original = try Data(contentsOf: input)
    let destination = fixture.url("runtime.png")
    let request = try TransformationRequest(legacy: .init(input: input, destination: destination, format: .png))
    let runtime = JobRuntime()
    let job = await runtime.submit(request)
    let events = try await collectedEvents(job)
    try expectEventContract(events, jobID: job.id)
    guard case .completed(let result) = events.last?.payload else { Issue.record("Expected completed job"); return }
    #expect(result.status == .succeeded)
    #expect(result.artifacts.count == 1 && result.artifacts[0].url == destination)
    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(try Data(contentsOf: input) == original)
    #expect(await runtime.activeJobCount == 0)
}

@Test func runtimeFailedJobTerminatesAndNextIndependentJobSucceeds() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let badInput = fixture.url("damaged.png")
    try Data("invalid image".utf8).write(to: badInput)
    let badDestination = fixture.url("never.png")
    let runtime = JobRuntime()
    let badJob = await runtime.submit(try .init(legacy: .init(input: badInput, destination: badDestination, format: .png)))
    let failedEvents = try await collectedEvents(badJob)
    try expectEventContract(failedEvents, jobID: badJob.id)
    guard case .failed(let failure) = failedEvents.last?.payload else { Issue.record("Expected failed job"); return }
    #expect(failure.code == .unsupported)
    #expect(!FileManager.default.fileExists(atPath: badDestination.path))
    let input = try fixture.image()
    let nextJob = await runtime.submit(try .init(legacy: .init(input: input, destination: fixture.url("next.png"), format: .png)))
    let nextEvents = try await collectedEvents(nextJob)
    try expectEventContract(nextEvents, jobID: nextJob.id)
    #expect(nextJob.id != badJob.id)
    guard case .completed(let result) = nextEvents.last?.payload else { Issue.record("Next job did not recover"); return }
    #expect(result.status == .succeeded)
    #expect(await runtime.activeJobCount == 0)
}

@Test func runtimeImmediateCancellationCleansStagingAndHasOneTerminal() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image(width: 640, height: 480)
    let original = try Data(contentsOf: input)
    let destination = fixture.url("cancelled.png")
    let runtime = JobRuntime()
    let job = await runtime.submit(try .init(legacy: .init(input: input, destination: destination, format: .png)))
    await runtime.cancel(job.id)
    let events = try await collectedEvents(job)
    try expectEventContract(events, jobID: job.id)
    switch try #require(events.last).payload {
    case .failed(let failure):
        #expect(failure.code == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    case .completed(let result):
        // Cancellation may arrive after the atomic commit; that remains success.
        #expect(result.status == .succeeded)
        let artifact = try #require(result.artifacts.first)
        #expect(artifact.url == destination)
        #expect(FileManager.default.fileExists(atPath: artifact.url.path))
        let actualBytes = Int64(try Data(contentsOf: artifact.url).count)
        #expect(actualBytes == artifact.bytes)
    default: Issue.record("Cancellation must end in a terminal event")
    }
    #expect(try Data(contentsOf: input) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".fileform-") })
    #expect(await runtime.activeJobCount == 0)
    await runtime.cancel(job.id)
    #expect(await runtime.activeJobCount == 0)
}

private func expectInventoryMatchesLegacy(_ inventory: CapabilityInventory, legacy: [Capability]) throws {
    #expect(inventory.schemaVersion == 1)
    #expect(!inventory.engineVersion.isEmpty && !inventory.platformVersion.isEmpty)
    let conversions = inventory.routes.filter { $0.operationID == .conversion }
    #expect(conversions.count == legacy.count)
    #expect(Set(inventory.routes.map(\.id)).count == inventory.routes.count)
    for route in inventory.routes where route.operationID == .fetch {
        #expect(!route.localProcessing && route.backend == "direct-http" && route.inputFamilies.isEmpty)
        #expect(route.available == legacy.contains { $0.engine == "ffmpeg" && $0.available })
    }
    for (route, previous) in zip(conversions, legacy) {
        #expect(route.outputFormat == previous.format)
        #expect(route.goals == previous.goals)
        #expect(route.backend == previous.engine)
        #expect(route.available == previous.available)
        #expect(route.limitation == previous.limitation)
        #expect(route.cardinality == .file && route.localProcessing)
        #expect(!route.verification.isEmpty)
    }
}

@Test func capabilityInventoriesRetainLegacyRoutesAndDeclareNetworkFetchSeparately() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let native = ConversionEngine()
    let nativeInventory = await native.capabilityInventory()
    try expectInventoryMatchesLegacy(nativeInventory, legacy: await native.capabilities())
    #expect(nativeInventory.inputFamily == nil)
    #expect(nativeInventory.routes.contains { $0.backend == "imageio" && $0.available })
    let inspection = try await native.inspect(input)
    let imageInventory = await native.capabilityInventory(for: inspection)
    try expectInventoryMatchesLegacy(imageInventory, legacy: await native.capabilities(for: inspection))
    #expect(imageInventory.inputFamily == .image)
    #expect(imageInventory.routes.allSatisfy { $0.inputFamilies.contains(.image) })
    let missing = ConversionEngine(mediaPack: fixture.url("missing-pack"))
    let missingInventory = await missing.capabilityInventory()
    try expectInventoryMatchesLegacy(missingInventory, legacy: await missing.capabilities())
    let media = missingInventory.routes.filter { $0.backend == "ffmpeg" }
    #expect(!media.isEmpty)
    #expect(media.allSatisfy { !$0.available && $0.backendVersion == nil })
    #expect(missingInventory.routes.contains { $0.backend == "imageio" && $0.available })
}

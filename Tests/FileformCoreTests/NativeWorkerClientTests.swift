// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import ImageIO
import Testing
import FileformDomain
import FileformCore

private func builtNativeWorker() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let executable = root.appendingPathComponent(".build/debug/fileform-worker")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path), "The built native worker is required; this test must not skip isolation verification.")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw FileformError(.engineUnavailable, "Build fileform-worker before running client tests.")
    }
    return executable
}

private func shellLiteral(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private struct HostileWorkerFixture {
    let directory: URL
    let executable: URL
    init(in fixture: Fixture, behavior: String) throws {
        directory = fixture.url("hostile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        executable = directory.appendingPathComponent("worker.sh")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$$" > \(shellLiteral(directory.appendingPathComponent("leader.pid").path))
        printf '%s\\n' "$TMPDIR" > \(shellLiteral(directory.appendingPathComponent("scratch.path").path))
        /bin/sleep 30 &
        printf '%s\\n' "$!" > \(shellLiteral(directory.appendingPathComponent("child.pid").path))
        \(behavior)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    var pids: [pid_t] {
        ["leader.pid", "child.pid", "flood.pid"].compactMap { name in
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
            return pid
        }
    }
    func cleanupProcesses() {
        for pid in pids where (try? processIsLive(pid)) == true { kill(pid, SIGKILL) }
    }
    func waitForStartup() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while pids.count < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(pids.count >= 2, "The controlled worker must launch before cancellation is tested.")
    }
    func assertStoppedAndCleaned() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while try pids.contains(where: processIsLive), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pids.count >= 2)
        for pid in pids { #expect(try !processIsLive(pid), "Worker process \(pid) must be dead or a zombie awaiting OS reaping.") }
        let scratch = try String(contentsOf: directory.appendingPathComponent("scratch.path"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!scratch.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: scratch), "Job-owned worker scratch must be removed after termination.")
    }
}

private func processIsLive(_ pid: pid_t) throws -> Bool {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", String(pid), "-o", "stat="]
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let state = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return !state.isEmpty && !state.hasPrefix("Z")
}

@Test func nativeWorkerClientInspectsAndDecodesRealPreviewWithoutChangingSource() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image(width: 320, height: 240)
    let before = try Data(contentsOf: input)
    let client = NativeWorkerClient(executable: try builtNativeWorker())
    let inspection = try await client.inspect(input)
    #expect(inspection.input == input && inspection.family == .image)
    #expect(inspection.width == 320 && inspection.height == 240)
    let preview = try await client.preview(input, maximumDimension: 80)
    #expect(preview.identity == inspection.identity)
    #expect(preview.width == 80 && preview.height == 60)
    let imageSource = try #require(CGImageSourceCreateWithData(preview.png as CFData, nil))
    #expect(CGImageSourceGetType(imageSource) as String? == "public.png")
    let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    #expect(image.width == 80 && image.height == 60)
    #expect(try Data(contentsOf: input) == before)
}

@Test func nativeWorkerClientRecoversAfterMalformedInput() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let bad = fixture.url("bad.png")
    try Data("this is not an image".utf8).write(to: bad)
    let client = NativeWorkerClient(executable: try builtNativeWorker())
    do { _ = try await client.inspect(bad); Issue.record("Malformed input unexpectedly inspected") }
    catch let failure as FileformError { #expect(failure.code == .unsupported) }
    let good = try fixture.image()
    #expect(try await client.inspect(good).family == .image)
}

@Test func nativeWorkerClientStopsDescendantAfterLeaderExits() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let hostile = try HostileWorkerFixture(in: fixture, behavior: "exit 0")
    defer { hostile.cleanupProcesses() }
    // This case measures leader-exit teardown, not interpreter startup speed.
    // Leave startup headroom when the complete fixture suite runs in parallel.
    let client = NativeWorkerClient(executable: hostile.executable, timeout: 4)
    let start = ContinuousClock.now
    await #expect(throws: FileformError.self) { try await client.inspect(input) }
    #expect(start.duration(to: .now) < .seconds(5))
    try await hostile.assertStoppedAndCleaned()
}

@Test func nativeWorkerClientTimeoutStopsWholeGroupAndCleansScratch() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let before = try Data(contentsOf: input)
    let hostile = try HostileWorkerFixture(in: fixture, behavior: "wait")
    defer { hostile.cleanupProcesses() }
    let client = NativeWorkerClient(executable: hostile.executable, timeout: 1.5)
    let start = ContinuousClock.now
    do { _ = try await client.inspect(input); Issue.record("Hanging worker unexpectedly completed") }
    catch let failure as FileformError { #expect(failure.code == .engineFailed) }
    #expect(start.duration(to: .now) < .seconds(5))
    try await hostile.assertStoppedAndCleaned()
    #expect(try Data(contentsOf: input) == before)
}

@Test(arguments: [0, 3]) func nativeWorkerClientCancellationStopsWholeGroupAndCleansScratch(startupDelaySeconds: Int) async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    let hostile = try HostileWorkerFixture(in: fixture, behavior: "wait")
    defer { hostile.cleanupProcesses() }
    let client = NativeWorkerClient(executable: hostile.executable, timeout: 30)
    let task = Task {
        if startupDelaySeconds > 0 { try await Task.sleep(for: .seconds(startupDelaySeconds)) }
        return try await client.inspect(input)
    }
    // Queue/launch latency is separate from the cancellation guarantee. A
    // delayed start must still exercise a live process group, not cancel a
    // task which never reached the worker. Keep a bounded startup deadline.
    do { try await hostile.waitForStartup() }
    catch { task.cancel(); _ = await task.result; throw error }
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(5))
    try await hostile.assertStoppedAndCleaned()
}

@Test func nativeWorkerClientRejectsOversizedProtocolAndStopsWriters() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let input = try fixture.image()
    // Advertise a 2 MiB frame before flooding. The header alone exceeds the
    // per-frame ceiling; rejection must not depend on pipe throughput.
    let hostile = try HostileWorkerFixture(in: fixture, behavior: """
    (
        while [ ! -s "$(dirname "$0")/flood.pid" ]; do /bin/sleep 0.01; done
        printf '\\000\\040\\000\\000'
        /bin/dd if=/dev/zero bs=65536 count=64
    ) &
    printf '%s\\n' "$!" > "$(dirname "$0")/flood.pid"
    wait
    """)
    defer { hostile.cleanupProcesses() }
    let client = NativeWorkerClient(executable: hostile.executable, timeout: 2)
    let start = ContinuousClock.now
    do { _ = try await client.inspect(input); Issue.record("Oversized response unexpectedly accepted") }
    catch let failure as FileformError { #expect(failure.code == .resourceLimit) }
    #expect(start.duration(to: .now) < .seconds(5))
    try await hostile.assertStoppedAndCleaned()
    #expect(hostile.pids.count == 3)
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import CryptoKit
import Darwin
import FileformDomain
@testable import FileformCore

@Suite(.serialized)
struct DirectHTTPClientTests {
    @Test func policyRejectsCredentialsSchemesAndInvalidLimits() throws {
        let policy = try HTTPAcquisitionPolicy(maximumBytes: 1024, allowedHosts: ["example.com"])
        for text in ["http://example.com/file", "https://user:secret@example.com/file", "file:///tmp/file", "https://other.example/file"] {
            #expect(throws: FileformError.self) { try policy.validate(URL(string: text)!) }
        }
        try policy.validate(URL(string: "https://example.com/file?token=opaque")!)
        #expect(throws: FileformError.self) { try HTTPAcquisitionPolicy(maximumBytes: 0) }
        #expect(throws: FileformError.self) { try HTTPAcquisitionPolicy(maximumBytes: 10, timeout: .infinity) }
    }
    @Test func realHTTPMetadataRedirectAndBytesAreMeasuredWithoutCookies() async throws {
        let fixture = try HTTPFixture(); defer { fixture.cleanup() }
        let client = DirectHTTPClient(stagingRoot: fixture.directory)
        let policy = try fixture.policy(bytes: 300000)
        let metadata = try await client.inspect(fixture.url("/payload"), policy: policy)
        #expect(metadata.expectedBytes == 262144)
        let downloaded = try await client.download(fixture.url("/redirect"), policy: policy)
        let bytes = try Data(contentsOf: downloaded.url)
        #expect(bytes == Data(repeating: 65, count: 262144))
        #expect(downloaded.metadata.url.path == "/payload")
        #expect(downloaded.bytes == 262144)
        #expect(downloaded.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        downloaded.discard(); downloaded.discard()
        #expect(!FileManager.default.fileExists(atPath: downloaded.url.path))
        // A previous response sets a cookie, but the following request must not send it.
        let cookie = try await client.download(fixture.url("/cookie"), policy: policy); cookie.discard()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }
    @Test func knownAndUnknownLengthsCannotExceedLimitOrLeaveStaging() async throws {
        let fixture = try HTTPFixture(); defer { fixture.cleanup() }
        let client = DirectHTTPClient(stagingRoot: fixture.directory)
        for path in ["/payload", "/unknown"] {
            do {
                _ = try await client.download(fixture.url(path), policy: fixture.policy(bytes: 1024))
                Issue.record("Oversized transfer unexpectedly succeeded")
            } catch let error as FileformError { #expect(error.code == .resourceLimit) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        }
    }
    @Test func redirectsAuthAndCodingCannotEscapePolicy() async throws {
        let fixture = try HTTPFixture(); defer { fixture.cleanup() }
        let client = DirectHTTPClient(stagingRoot: fixture.directory)
        for path in ["/loop", "/cross", "/auth", "/encoded", "/truncated"] {
            await #expect(throws: FileformError.self) {
                try await client.download(fixture.url(path), policy: fixture.policy(bytes: 300000))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        }
    }
    @Test func resourceTimeoutCleansOwnedStaging() async throws {
        let fixture = try HTTPFixture(); defer { fixture.cleanup() }
        let client = DirectHTTPClient(stagingRoot: fixture.directory)
        let policy = try HTTPAcquisitionPolicy(maximumBytes: 300000, timeout: 1, allowInsecureHTTP: true)
        await #expect(throws: FileformError.self) { try await client.download(fixture.url("/stall"), policy: policy) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }
    @Test func cancellationWaitsForTransportAndCleansOwnedBytes() async throws {
        let fixture = try HTTPFixture(); defer { fixture.cleanup() }
        let client = DirectHTTPClient(stagingRoot: fixture.directory)
        let observed = HTTPByteProbe()
        let task = Task { try await client.download(fixture.url("/slow"), policy: fixture.policy(bytes: 300000)) { bytes, _ in observed.set(bytes) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while observed.bytes == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(observed.bytes > 0)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        let preCancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await client.download(fixture.url("/payload"), policy: fixture.policy(bytes: 300000)) }
        await #expect(throws: CancellationError.self) { try await preCancelled.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }
}

private final class HTTPByteProbe: @unchecked Sendable {
    private let lock = NSLock(); private var value: Int64 = 0
    var bytes: Int64 { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Int64) { lock.lock(); self.value = value; lock.unlock() }
}

private final class HTTPFixture: @unchecked Sendable {
    let directory: URL
    private let process: Process
    private let completion: DispatchSemaphore
    let port: Int
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let completed = DispatchSemaphore(value: 0); completion = completed
        process = Process(); let pipe = Pipe()
        process.terminationHandler = { _ in completed.signal() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", #"""
import http.server,time
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_HEAD(self):
  self.send_response(200);self.send_header('Content-Length','262144');self.end_headers()
 def do_GET(self):
  p=self.path
  if p=='/stall':time.sleep(2)
  if p in ['/redirect','/loop','/cross']:
   self.send_response(302);self.send_header('Set-Cookie','private=must-not-be-sent');self.send_header('Location', '/payload' if p=='/redirect' else '/loop' if p=='/loop' else 'http://localhost:%d/payload'%self.server.server_port);self.end_headers();return
  if p=='/auth':
   self.send_response(401);self.send_header('WWW-Authenticate','Basic realm="fixture"');self.end_headers();return
  if self.headers.get('Cookie') or self.headers.get('Authorization'):
   self.send_response(403);self.end_headers();return
  self.send_response(200)
  if p=='/encoded':self.send_header('Content-Encoding','gzip')
  if p not in ['/unknown','/slow']:self.send_header('Content-Length','262144')
  self.send_header('Content-Type','application/octet-stream');self.send_header('Set-Cookie','private=must-not-be-sent');self.end_headers()
  try:
   if p=='/truncated':self.wfile.write(b'A');return
   if p=='/slow':
    for i in range(256):self.wfile.write(b'A'*1024);self.wfile.flush();time.sleep(.02)
   else:self.wfile.write(b'A'*262144)
  except (BrokenPipeError,ConnectionResetError):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
print('%07d'%server.server_port,flush=True);server.serve_forever()
"""#]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try pipe.fileHandleForReading.read(upToCount: 8) ?? Data()
        guard let value = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate(); throw FileformError(.engineFailed, "Fixture failed to start")
        }
        port = value
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func policy(bytes: Int64) throws -> HTTPAcquisitionPolicy {
        try .init(maximumBytes: bytes, timeout: 5, maximumRedirects: 2, allowInsecureHTTP: true, allowedHosts: ["127.0.0.1"])
    }
    func cleanup() {
        if process.isRunning { process.terminate() }
        if completion.wait(timeout: .now() + 3) == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            #expect(completion.wait(timeout: .now() + 3) == .success, "Fixture process did not finish cleanup")
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

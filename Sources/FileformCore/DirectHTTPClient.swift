// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import FileformDomain

/// Every initial and redirected request is validated against the same policy.
/// This local client is not a hosted URL proxy or an SSRF boundary.
public struct HTTPAcquisitionPolicy: Sendable {
    public let maximumBytes: Int64
    public let timeout: TimeInterval
    public let maximumRedirects: Int
    public let allowInsecureHTTP: Bool
    public let allowedHosts: Set<String>?
    public init(maximumBytes: Int64, timeout: TimeInterval = 120, maximumRedirects: Int = 5,
                allowInsecureHTTP: Bool = false, allowedHosts: Set<String>? = nil) throws {
        guard maximumBytes > 0, maximumBytes <= 8 * 1024 * 1024 * 1024,
              timeout.isFinite, (1...600).contains(timeout), (0...8).contains(maximumRedirects) else {
            throw FileformError(.invalidRequest, "Choose a positive download limit up to 8 GiB, a timeout of 1–600 seconds and at most eight redirects.")
        }
        self.maximumBytes = maximumBytes; self.timeout = timeout; self.maximumRedirects = maximumRedirects
        self.allowInsecureHTTP = allowInsecureHTTP; self.allowedHosts = allowedHosts.map { Set($0.map { $0.lowercased() }) }
    }
    public func validate(_ url: URL) throws {
        guard url.absoluteString.utf8.count <= 8192, let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              url.scheme?.lowercased() == "https" || (allowInsecureHTTP && url.scheme?.lowercased() == "http"),
              allowedHosts.map({ $0.contains(host) }) ?? true,
              url.port.map({ (1...65535).contains($0) }) ?? true else {
            throw FileformError(.invalidRequest, "This URL is not permitted by the download policy. Use an allowed HTTP(S) host without embedded credentials.")
        }
    }
}

public struct HTTPResourceMetadata: Sendable {
    public let url: URL
    public let contentType: String?
    public let expectedBytes: Int64?
    public let entityTag: String?
    public let lastModified: String?
}

/// Owned raw download. Transport integrity is not media/content verification.
/// The acquisition adapter must inspect it before publishing a user result.
public final class DownloadedResource: @unchecked Sendable {
    public let url: URL
    public let metadata: HTTPResourceMetadata
    public let bytes: Int64
    public let sha256: String
    private let directory: URL
    private let lock = NSLock()
    private var removed = false
    fileprivate init(url: URL, directory: URL, result: HTTPTransferResult) {
        self.url = url; self.directory = directory; metadata = result.metadata
        bytes = result.bytes; sha256 = result.sha256
    }
    public func discard() {
        lock.lock(); defer { lock.unlock() }
        guard !removed else { return }
        removed = true; try? FileManager.default.removeItem(at: directory)
    }
    deinit { discard() }
}

public struct DirectHTTPClient: Sendable {
    private let stagingRoot: URL
    public init() { stagingRoot = FileManager.default.temporaryDirectory }
    init(stagingRoot: URL) { self.stagingRoot = stagingRoot }

    public func inspect(_ url: URL, policy: HTTPAcquisitionPolicy) async throws -> HTTPResourceMetadata {
        try policy.validate(url)
        return try await transfer(url, method: "HEAD", policy: policy, writer: nil, progress: { _, _ in }).metadata
    }

    public func download(_ url: URL, policy: HTTPAcquisitionPolicy,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> DownloadedResource {
        try policy.validate(url); try Task.checkCancellation()
        let directory = stagingRoot.appendingPathComponent("fileform-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        let payload = directory.appendingPathComponent("payload")
        guard FileManager.default.createFile(atPath: payload.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw FileformError(.ioFailure, "Could not create download staging.")
        }
        let writer = try FileHandle(forWritingTo: payload)
        defer { try? writer.close() }
        let result = try await transfer(url, method: "GET", policy: policy, writer: writer, progress: progress)
        try Task.checkCancellation()
        try writer.synchronize(); try writer.close()
        retained = true
        return DownloadedResource(url: payload, directory: directory, result: result)
    }

    private func transfer(_ url: URL, method: String, policy: HTTPAcquisitionPolicy, writer: FileHandle?,
                          progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> HTTPTransferResult {
        let transfer = HTTPTransfer(policy: policy, writer: writer, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(url: url, method: method, continuation: continuation)
            }
        } onCancel: { transfer.cancel() }
    }
}

private struct HTTPTransferResult: Sendable {
    let metadata: HTTPResourceMetadata
    let bytes: Int64
    let sha256: String
}

/// Delegate state is confined to one serial queue. Only cancellation and the
/// task handoff cross threads, and those two fields are protected by a lock.
private final class HTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let policy: HTTPAcquisitionPolicy
    let writer: FileHandle?
    let progress: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<HTTPTransferResult, Error>?
    private var session: URLSession?
    private var metadata: HTTPResourceMetadata?
    private var failure: Error?
    private var received: Int64 = 0
    private var redirects = 0
    private var digest = SHA256()
    init(policy: HTTPAcquisitionPolicy, writer: FileHandle?, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.policy = policy; self.writer = writer; self.progress = progress
    }
    func start(url: URL, method: String, continuation: CheckedContinuation<HTTPTransferResult, Error>) {
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = policy.timeout; config.timeoutIntervalForResource = policy.timeout
        config.waitsForConnectivity = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        lock.lock(); self.task = task; let wasCancelled = cancelled; lock.unlock()
        task.resume()
        if wasCancelled { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        do {
            redirects += 1
            guard redirects <= policy.maximumRedirects, let url = request.url else {
                throw FileformError(.resourceLimit, "The download exceeded its redirect limit.")
            }
            try policy.validate(url)
            guard response.url?.scheme?.lowercased() != "https" || url.scheme?.lowercased() == "https" else {
                throw FileformError(.invalidRequest, "An HTTPS download cannot redirect to an insecure connection.")
            }
            var approved = request
            approved.httpMethod = task.originalRequest?.httpMethod ?? "GET"
            approved.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            approved.setValue(nil, forHTTPHeaderField: "Authorization")
            approved.setValue(nil, forHTTPHeaderField: "Cookie")
            completionHandler(approved)
        } catch { failure = error; completionHandler(nil); task.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard failure == nil else { completionHandler(.cancel); return }
        do {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let url = http.url else {
                throw FileformError(.engineFailed, "The source did not return a complete successful HTTP response.")
            }
            try policy.validate(url)
            let coding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            guard coding == nil || coding == "identity" else { throw FileformError(.unsupported, "The source ignored the request for an uncompressed download.") }
            let length = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            guard length.map({ $0 <= policy.maximumBytes }) ?? true else { throw FileformError(.resourceLimit, "The source exceeds the download byte limit.") }
            metadata = .init(url: url, contentType: response.mimeType, expectedBytes: length,
                             entityTag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            guard Int64(data.count) <= policy.maximumBytes - received else { throw FileformError(.resourceLimit, "The download exceeded its byte limit.") }
            try writer?.write(contentsOf: data)
            digest.update(data: data); received += Int64(data.count)
            progress(received, metadata?.expectedBytes)
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.invalidateAndCancel(); self.session = nil; continuation = nil }
        lock.lock(); let wasCancelled = cancelled; self.task = nil; lock.unlock()
        if wasCancelled { continuation?.resume(throwing: CancellationError()); return }
        if let failure { continuation?.resume(throwing: failure); return }
        if error != nil { continuation?.resume(throwing: FileformError(.engineFailed, "The download failed or timed out. Check the source and try again.")); return }
        guard let metadata, writer == nil || (received > 0 && metadata.expectedBytes.map({ $0 == received }) ?? true) else {
            continuation?.resume(throwing: FileformError(.verificationFailed, "The download is empty or does not match its declared length.")); return
        }
        continuation?.resume(returning: .init(metadata: metadata, bytes: received,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()))
    }
}

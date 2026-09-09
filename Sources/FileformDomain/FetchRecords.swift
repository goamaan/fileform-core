// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Remote request binding, kept in plans but never portable saved setups.
public struct FetchSourceSnapshot: Codable, Equatable, Sendable {
    public let requestedURL: URL
    public let resolvedURL: URL
    public let contentType: String?
    public let expectedBytes: Int64?
    public let entityTag: String?
    public let lastModified: String?
    public init(requestedURL: URL, resolvedURL: URL, contentType: String?, expectedBytes: Int64?, entityTag: String?, lastModified: String?) {
        self.requestedURL = requestedURL; self.resolvedURL = resolvedURL; self.contentType = contentType
        self.expectedBytes = expectedBytes; self.entityTag = entityTag; self.lastModified = lastModified
    }
}

/// A receipt identifies the published bytes without retaining signed URL queries.
public struct FetchReceipt: Codable, Equatable, Sendable {
    public let sourceHost: String
    public let bytes: Int64
    public let sha256: String
    public init(sourceHost: String, bytes: Int64, sha256: String) {
        self.sourceHost = sourceHost; self.bytes = bytes; self.sha256 = sha256
    }
}

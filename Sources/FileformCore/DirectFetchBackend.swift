// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import FileformDomain

/// Direct media retrieval preserves the complete source bytes. It never treats
/// an HTML page or an advertised MIME type as proof of downloadable media.
struct DirectFetchBackend {
    static let formats: [OutputFormat] = [.mp4, .mov, .m4a, .wav, .flac, .mp3]
    let media: MediaBackend
    private let client = DirectHTTPClient()

    func plan(_ request: TransformationRequest) async throws -> TransformationPlan {
        let (url, policy) = try parameters(request)
        let metadata = try await client.inspect(url, policy: policy)
        let source = FetchSourceSnapshot(requestedURL: url, resolvedURL: metadata.url,
            contentType: metadata.contentType, expectedBytes: metadata.expectedBytes,
            entityTag: metadata.entityTag, lastModified: metadata.lastModified)
        var warnings = ["This contacts the source and any permitted redirects. It does not use browser cookies or sign in.",
                        "The original downloaded bytes and metadata are kept. Content and file type are verified before saving; no conversion is performed."]
        if url.scheme?.lowercased() == "http" { warnings.append("This source uses unencrypted HTTP.") }
        if metadata.entityTag == nil || metadata.entityTag?.hasPrefix("W/") == true {
            warnings.append("The source provides no strong content version. Response properties are checked again, but lookup cannot promise immutable source bytes.")
        }
        return .init(request: request, inputs: [], warnings: warnings, fetchSource: source)
    }

    func execute(_ plan: TransformationPlan, progress: @escaping @Sendable (ProgressEvent) -> Void) async throws -> TransformationResult {
        let (_, policy) = try parameters(plan.request)
        guard plan.schemaVersion == 1, plan.inputs.isEmpty, let expected = plan.fetchSource else {
            throw FileformError(.invalidRequest, "The fetch plan is missing its source binding.")
        }
        // Serialized plans do not authorize a different URL or forged validators.
        progress(.init(.inspecting))
        let current = try await self.plan(plan.request)
        guard current.fetchSource == expected else { throw FileformError(.inputChanged, "The source changed after lookup. Look up the link again.") }
        let matching = HTTPResourceMetadata(url: expected.resolvedURL, contentType: expected.contentType,
            expectedBytes: expected.expectedBytes, entityTag: expected.entityTag, lastModified: expected.lastModified)
        progress(.init(.preparing))
        let downloaded = try await client.download(expected.resolvedURL, policy: policy, matching: matching) { bytes, total in
            progress(.init(.preparing, fraction: total.flatMap { $0 > 0 ? Double(bytes) / Double($0) : nil }))
        }
        defer { downloaded.discard() }
        try Task.checkCancellation()
        let transaction = try OutputTransaction(destination: plan.request.output.destination, input: downloaded.url,
                                                collisionPolicy: plan.request.collisionPolicy)
        defer { transaction.cleanup() }
        let candidate = transaction.candidate(1, format: plan.request.output.format)
        try FileManager.default.copyItem(at: downloaded.url, to: candidate)
        progress(.init(.verifying))
        try await verify(candidate, as: plan.request.output.format)
        guard try hash(candidate) == downloaded.sha256,
              try FileSafety.identity(candidate).bytes == downloaded.bytes else {
            throw FileformError(.verificationFailed, "The staged media differs from the received source bytes.")
        }
        try Task.checkCancellation()
        progress(.init(.saving))
        let destination = try transaction.commit(candidate)
        return .init(operationID: .fetch, status: .succeeded,
            artifacts: [.init(url: destination, format: plan.request.output.format, bytes: downloaded.bytes, sourceIDs: [])],
            warnings: current.warnings, attempts: 1,
            fetchReceipt: .init(sourceHost: expected.resolvedURL.host ?? "", bytes: downloaded.bytes, sha256: downloaded.sha256))
    }

    private func parameters(_ request: TransformationRequest) throws -> (URL, HTTPAcquisitionPolicy) {
        try request.validate()
        guard case .fetch(let url, let maximum) = request.operation, Self.formats.contains(request.output.format) else {
            throw FileformError(.unsupported, "Direct fetch currently saves verified MP4, MOV, M4A, WAV, FLAC or MP3 source files. Web-page extraction requires a downloader adapter.")
        }
        return (url, try .init(maximumBytes: maximum, allowInsecureHTTP: url.scheme?.lowercased() == "http"))
    }

    private func verify(_ input: URL, as format: OutputFormat) async throws {
        let demuxer = [OutputFormat.mp4, .mov, .m4a].contains(format) ? "mov" : format.rawValue
        let demuxerOptions = ["-f", demuxer] + (demuxer == "mov" ? ["-enable_drefs", "0"] : [])
        let probe = try await media.probe(input, forcedDemuxer: demuxer)
        let containers = Set(probe.format.format_name?.split(separator: ",").map(String.init) ?? [])
        let brand = probe.format.tags?["major_brand"]
        let matches: Bool
        switch format {
        case .wav: matches = containers.contains("wav") && probe.videos.isEmpty
        case .flac: matches = containers.contains("flac") && probe.videos.isEmpty
        case .mp3: matches = containers.contains("mp3") && probe.videos.isEmpty
        case .mp4: matches = containers.contains("mov") && brand != nil && brand != "qt  "
        case .mov: matches = containers.contains("mov") && (brand == nil || brand == "qt  ")
        case .m4a: matches = containers.contains("mov") && probe.videos.isEmpty && !probe.audios.isEmpty && probe.audios.allSatisfy { ["aac", "alac"].contains($0.codec_name ?? "") }
        default: matches = false
        }
        guard matches, !probe.videos.isEmpty || !probe.audios.isEmpty else {
            throw FileformError(.verificationFailed, "The received file is not the chosen media type. No result was saved.")
        }
        guard probe.streams.count <= 16, probe.videos.count <= 4, probe.audios.count <= 8,
              let duration = probe.format.duration.flatMap(Double.init), duration.isFinite, duration > 0, duration <= 21600 else {
            throw FileformError(.resourceLimit, "This media exceeds the verification limits: six hours, four video tracks and eight audio tracks.")
        }
        for video in probe.videos {
            guard let width = video.width, let height = video.height, width > 0, height > 0,
                  width <= 16384, height <= 16384, width * height <= 64_000_000 else {
                throw FileformError(.resourceLimit, "The downloaded picture exceeds the verification dimension limit.")
            }
        }
        for audio in probe.audios {
            guard let channels = audio.channels, (1...8).contains(channels),
                  let rate = audio.sample_rate.flatMap(Int.init), (1...192000).contains(rate) else {
                throw FileformError(.resourceLimit, "The downloaded audio exceeds the channel or sample-rate verification limit.")
            }
        }
        let decoded = try await ProcessRunner.run(executable: media.pack.ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-v", "error", "-xerror", "-err_detect", "explode", "-max_alloc", "268435456",
            "-protocol_whitelist", "file,pipe", "-threads", "2"
        ] + demuxerOptions + ["-i", input.path, "-map", "0:v?", "-map", "0:a?", "-progress", "pipe:1", "-f", "null", "-"
        ], timeout: min(600, max(30, duration + 10)))
        let progress = String(decoding: decoded.stdout, as: UTF8.self)
        let decodedTimes = progress.split(separator: "\n").compactMap { line -> Int64? in
            guard line.hasPrefix("out_time_us=") else { return nil }
            return Int64(line.dropFirst("out_time_us=".count))
        }
        guard decoded.status == 0, progress.contains("progress=end"), decodedTimes.contains(where: { $0 > 0 }) else { throw FileformError(.verificationFailed, "The complete downloaded media could not be decoded. No result was saved.") }
    }
    private func hash(_ input: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: input); defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 262144), !data.isEmpty {
            try Task.checkCancellation(); digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Signed timestamp in a media stream's clock. User-selected intervals continue
/// to use nonnegative MediaTime values in the normalized playback clock.
public struct MediaTimestamp: Codable, Equatable, Sendable {
    public let ticks: Int64
    public let timescale: Int32
    public init(ticks: Int64, timescale: Int32) { self.ticks = ticks; self.timescale = timescale }
}

public struct MediaAudioTrack: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public let ordinal: Int
    public let index: Int
    public let codec: String
    public let sampleRate: Int
    public let channels: Int
    public let origin: MediaTimestamp
    public let duration: MediaTime
    public let decodedSamples: Int64
    public let continuousSampleClock: Bool
    public let timelineCompatible: Bool
    public let limitation: String?
    public init(ordinal: Int, index: Int, codec: String, sampleRate: Int, channels: Int,
                origin: MediaTimestamp, duration: MediaTime, decodedSamples: Int64,
                continuousSampleClock: Bool, timelineCompatible: Bool, limitation: String? = nil) {
        self.ordinal = ordinal; self.index = index; self.codec = codec; self.sampleRate = sampleRate; self.channels = channels
        self.origin = origin; self.duration = duration; self.decodedSamples = decodedSamples
        self.continuousSampleClock = continuousSampleClock; self.timelineCompatible = timelineCompatible; self.limitation = limitation
    }
}

public struct MediaVideoTrack: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let codec: String
    public let width: Int
    public let height: Int
    public let rotationDegrees: Int
    public let displayWidth: Int
    public let displayHeight: Int
    public let origin: MediaTimestamp
    public let duration: MediaTime
    public let frameCount: Int
    public let frameDuration: MediaTime?
    public let constantFrameTiming: Bool
    public init(index: Int, codec: String, width: Int, height: Int, rotationDegrees: Int,
                displayWidth: Int, displayHeight: Int, origin: MediaTimestamp, duration: MediaTime,
                frameCount: Int, frameDuration: MediaTime?, constantFrameTiming: Bool) {
        self.index = index; self.codec = codec; self.width = width; self.height = height; self.rotationDegrees = rotationDegrees
        self.displayWidth = displayWidth; self.displayHeight = displayHeight; self.origin = origin; self.duration = duration
        self.frameCount = frameCount; self.frameDuration = frameDuration; self.constantFrameTiming = constantFrameTiming
    }
}

public struct MediaTimeline: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let source: URL
    public let identity: FileIdentity
    public let container: String
    public let duration: MediaTime
    public let origin: MediaTimestamp
    public let audioTracks: [MediaAudioTrack]
    public let video: MediaVideoTrack?
    /// Conservative hint only. Clients may always request a verified proxy.
    public let originalPlaybackReliable: Bool
    public let warnings: [String]
    public init(source: URL, identity: FileIdentity, container: String, duration: MediaTime,
                origin: MediaTimestamp, audioTracks: [MediaAudioTrack], video: MediaVideoTrack?,
                originalPlaybackReliable: Bool, warnings: [String] = []) {
        schemaVersion = 1; self.source = source; self.identity = identity; self.container = container
        self.duration = duration; self.origin = origin; self.audioTracks = audioTracks; self.video = video
        self.originalPlaybackReliable = originalPlaybackReliable; self.warnings = warnings
    }
}

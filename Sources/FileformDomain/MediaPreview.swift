// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One measured bucket, with separate channel envelopes. Nothing is mixed or
/// padded to manufacture waveform data. Bounds are in the source playback clock.
public struct MediaWaveformBucket: Codable, Equatable, Sendable {
    public let interval: MediaInterval
    public let minimum: [Float]
    public let maximum: [Float]
    public init(interval: MediaInterval, minimum: [Float], maximum: [Float]) {
        self.interval = interval; self.minimum = minimum; self.maximum = maximum
    }
}

public struct MediaWaveform: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let source: URL
    public let identity: FileIdentity
    public let duration: MediaTime
    public let audioOrdinal: Int
    public let audioStreamIndex: Int
    public let sampleRate: Int
    public let channels: Int
    public let buckets: [MediaWaveformBucket]
    public init(source: URL, identity: FileIdentity, duration: MediaTime, audioOrdinal: Int,
                audioStreamIndex: Int, sampleRate: Int, channels: Int, buckets: [MediaWaveformBucket]) {
        schemaVersion = 1; self.source = source; self.identity = identity; self.duration = duration
        self.audioOrdinal = audioOrdinal; self.audioStreamIndex = audioStreamIndex; self.sampleRate = sampleRate
        self.channels = channels; self.buckets = buckets
    }
}

public struct MediaPoster: Sendable {
    public let png: Data
    public let identity: FileIdentity
    public let requestedTime: MediaTime
    public let realizedTime: MediaTime
    public let width: Int
    public let height: Int
    public init(png: Data, identity: FileIdentity, requestedTime: MediaTime, realizedTime: MediaTime, width: Int, height: Int) {
        self.png = png; self.identity = identity; self.requestedTime = requestedTime; self.realizedTime = realizedTime
        self.width = width; self.height = height
    }
}

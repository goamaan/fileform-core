// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Resolved trim measurements. Intervals use a zero-based source playback clock;
/// `realized` is the selected primary stream's half-open frame/sample range.
/// In copy mode compressed audio can overlap its edges by one packet, bounded by
/// `durationTolerance`; `outputDuration` reports the actual published container.
public struct MediaTrimDetails: Codable, Equatable, Sendable {
    public let requested: MediaInterval
    public let realized: MediaInterval
    public let mode: TrimMode
    /// Absolute ffprobe stream indices, unlike the request's audio-stream ordinal.
    public let videoStreamIndex: Int?
    public let audioStreamIndex: Int?
    public let copiedStreams: Bool
    public let durationTolerance: MediaTime
    public let outputDuration: MediaTime?
    public init(requested: MediaInterval, realized: MediaInterval, mode: TrimMode,
                videoStreamIndex: Int?, audioStreamIndex: Int?, copiedStreams: Bool,
                durationTolerance: MediaTime, outputDuration: MediaTime? = nil) {
        self.requested = requested; self.realized = realized; self.mode = mode
        self.videoStreamIndex = videoStreamIndex; self.audioStreamIndex = audioStreamIndex
        self.copiedStreams = copiedStreams; self.durationTolerance = durationTolerance
        self.outputDuration = outputDuration
    }
}

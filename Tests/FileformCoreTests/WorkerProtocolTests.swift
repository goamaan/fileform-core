// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import FileformDomain

@Test func workerFramesSurviveEverySplitAndConcatenation() throws {
    let asset = WorkerAssetHandle(assetID: "input-1", descriptor: 3)
    let requests = try [WorkerRequest(operation: .handshake),
                        WorkerRequest(operation: .inspect(asset: asset)),
                        WorkerRequest(operation: .preview(asset: asset, outputDescriptor: 4, maximumDimension: 640, pageIndex: 0))]
    for request in requests {
        let frame = try WorkerFrameCodec.encode(request)
        let declared = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(Int(declared) == frame.count - 4)
        for split in 0...frame.count {
            var decoder = try WorkerFrameDecoder<WorkerRequest>()
            let first = try decoder.append(Data(frame.prefix(split)))
            let second = try decoder.append(Data(frame.dropFirst(split)))
            #expect(first + second == [request])
            #expect(decoder.bufferedByteCount == 0)
            try decoder.finish()
        }
    }
    let combined = try requests.reduce(into: Data()) { $0.append(try WorkerFrameCodec.encode($1)) }
    var decoder = try WorkerFrameDecoder<WorkerRequest>()
    #expect(try decoder.append(combined) == requests)
    try decoder.finish()
    var bytewise = try WorkerFrameDecoder<WorkerRequest>()
    var decoded: [WorkerRequest] = []
    for byte in combined { decoded += try bytewise.append(Data([byte])) }
    #expect(decoded == requests)
    try bytewise.finish()
}

@Test func workerRejectsFrameLengthsBeforeBufferingPayload() throws {
    for (header, failure) in [(Data([0, 0, 0, 0]), WorkerProtocolError.emptyFrame),
                              (Data([0, 16, 0, 1]), .oversizedFrame),
                              (Data([255, 255, 255, 255]), .oversizedFrame)] {
        var decoder = try WorkerFrameDecoder<WorkerRequest>()
        #expect(try decoder.append(Data(header.prefix(3))).isEmpty)
        #expect(decoder.bufferedByteCount == 3)
        #expect(throws: failure) { try decoder.append(Data(header.suffix(1))) }
        #expect(decoder.bufferedByteCount == 0)
        #expect(throws: WorkerProtocolError.decoderClosed) { try decoder.append(Data()) }
    }
    #expect(throws: WorkerProtocolError.invalidFrameLimit) { try WorkerFrameDecoder<WorkerRequest>(maximumBytes: 0) }
    #expect(throws: WorkerProtocolError.invalidFrameLimit) { try WorkerFrameCodec.encode("x", maximumBytes: -1) }
    #expect(throws: WorkerProtocolError.oversizedFrame) { try WorkerFrameCodec.encode("too large", maximumBytes: 2) }
    let exact = try WorkerFrameCodec.encode("x", maximumBytes: 3)
    var decoder = try WorkerFrameDecoder<String>(maximumBytes: 3)
    #expect(try decoder.append(exact) == ["x"])
}

@Test func workerEOFRejectsIncompleteHeadersAndBodies() throws {
    let frame = try WorkerFrameCodec.encode(WorkerRequest(operation: .handshake))
    for count in 1..<frame.count {
        var decoder = try WorkerFrameDecoder<WorkerRequest>()
        #expect(try decoder.append(Data(frame.prefix(count))).isEmpty)
        #expect(throws: WorkerProtocolError.truncatedFrame) { try decoder.finish() }
        #expect(decoder.bufferedByteCount == 0)
    }
    var empty = try WorkerFrameDecoder<WorkerRequest>()
    try empty.finish()
    #expect(throws: WorkerProtocolError.decoderClosed) { try empty.append(frame) }
}

private func workerMutatedFrame(_ mutation: (inout [String: Any]) -> Void) throws -> Data {
    let request = try WorkerRequest(operation: .handshake)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    mutation(&object)
    let bytes = try JSONSerialization.data(withJSONObject: object)
    let count = UInt32(bytes.count)
    var frame = Data([UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
                      UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
    frame.append(bytes)
    return frame
}

@Test func workerRejectsMalformedMessagesVersionsAndUnknownOperations() throws {
    var malformed = try WorkerFrameDecoder<WorkerRequest>()
    #expect(throws: WorkerProtocolError.malformedMessage) { try malformed.append(Data([0, 0, 0, 1, 255])) }
    for version in [-1, 0, 2] {
        var decoder = try WorkerFrameDecoder<WorkerRequest>()
        let frame = try workerMutatedFrame { $0["version"] = version }
        #expect(throws: WorkerProtocolError.unsupportedVersion(version)) { try decoder.append(frame) }
    }
    var unknown = try WorkerFrameDecoder<WorkerRequest>()
    let frame = try workerMutatedFrame { $0["operation"] = ["execute": ["command": "unused"]] }
    #expect(throws: WorkerProtocolError.malformedMessage) { try unknown.append(frame) }
    var invalid = try WorkerFrameDecoder<WorkerRequest>()
    let invalidFrame = try workerMutatedFrame { $0["operation"] = ["inspect": ["asset": ["assetID": "a", "descriptor": 1]]] }
    #expect(throws: WorkerProtocolError.invalidRequest) { try invalid.append(invalidFrame) }
}

@Test func workerValidatesDescriptorBindingsAndPreviewBounds() throws {
    for descriptor: Int32 in [-1, 0, 1, 2] {
        #expect(throws: WorkerProtocolError.invalidRequest) {
            try WorkerRequest(operation: .inspect(asset: .init(assetID: "a", descriptor: descriptor)))
        }
    }
    for id in ["", String(repeating: "a", count: 129), "bad\nID", String(repeating: "é", count: 65)] {
        #expect(throws: WorkerProtocolError.invalidRequest) {
            try WorkerRequest(operation: .inspect(asset: .init(assetID: id, descriptor: 3)))
        }
    }
    let asset = WorkerAssetHandle(assetID: "source", descriptor: 3)
    for dimension in [0, -1, 4097] {
        #expect(throws: WorkerProtocolError.invalidRequest) {
            try WorkerRequest(operation: .preview(asset: asset, outputDescriptor: 4, maximumDimension: dimension, pageIndex: nil))
        }
    }
    #expect(throws: WorkerProtocolError.invalidRequest) {
        try WorkerRequest(operation: .preview(asset: asset, outputDescriptor: 3, maximumDimension: 640, pageIndex: nil))
    }
    #expect(throws: WorkerProtocolError.invalidRequest) {
        try WorkerRequest(operation: .preview(asset: asset, outputDescriptor: 4, maximumDimension: 640, pageIndex: -1))
    }
}

@Test func workerResponseInspectionIsPathFreeAndRoundTripsProperties() throws {
    let source = URL(fileURLWithPath: "/private/synthetic-input.png")
    let identity = FileIdentity(device: 1, inode: 2, bytes: 3, modifiedSeconds: 4, modifiedNanoseconds: 5)
    let inspection = Inspection(input: source, identity: identity, family: .image, detectedType: "public.png",
        width: 60, height: 40, frameCount: 1, hasAlpha: true, bitDepth: 8, orientation: 6,
        duration: 1.5, videoCodec: "h264", audioCodec: "aac", audioStreams: 2,
        pageCount: 3, tableRows: 4, tableColumns: 5, audioSampleFormat: "s16", audioBitDepth: 16, warnings: ["Curated warning"])
    let payload = try WorkerInspectionResult(assetID: "source", inspection: inspection)
    let response = try WorkerResponse(id: UUID(), payload: .inspection(payload))
    let frame = try WorkerFrameCodec.encode(response)
    #expect(!String(decoding: frame, as: UTF8.self).contains("/private/"))
    var decoder = try WorkerFrameDecoder<WorkerResponse>()
    let result = try #require(decoder.append(frame).first)
    #expect(result.id == response.id)
    guard case .inspection(let value) = result.payload else { Issue.record("Expected inspection"); return }
    #expect(value.assetID == "source")
    let rebound = value.inspection(rebindingTo: source)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(rebound) == encoder.encode(inspection))
    for payload in [WorkerResponsePayload.handshake(protocolVersion: 1), .preview(.init(bytes: 123, width: 32, height: 24)), .failure(.invalidInput)] {
        let response = try WorkerResponse(id: UUID(), payload: payload)
        var decoder = try WorkerFrameDecoder<WorkerResponse>()
        #expect(try decoder.append(WorkerFrameCodec.encode(response)).first?.id == response.id)
    }
    #expect(throws: WorkerProtocolError.unsupportedVersion(2)) { try WorkerResponse(id: UUID(), payload: .handshake(protocolVersion: 2)) }
    #expect(throws: WorkerProtocolError.invalidRequest) { try WorkerResponse(id: UUID(), payload: .preview(.init(bytes: 0, width: 32, height: 24))) }
}

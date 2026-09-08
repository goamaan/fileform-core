# Feasibility gates

Current: repository foundation and ImageIO probe. No production conversion API or CLI exists yet. A probe passing on one Mac does not establish the minimum supported OS.

1. Inventory runtime reader/writer support separately. **Initial ImageIO inventory and synthetic PNG-to-TIFF pixel round trip implemented.** Still needed: HEIC/AVIF, transparency, orientation, color/HDR and malformed input fixtures.
2. Build a distributable FFmpeg/ffprobe candidate with recorded flags, licenses and sources. Verify MKV/WebM-to-MP4, remux vs encoding, full-duration audio and size constraints. No media pack is selected yet.
3. Implement one shared image job through the library and CLI: inspect, immutable plan, temporary destination, reopen/verify, collision-safe commit and cancellation. Exercise races, invalid inputs and unchanged originals.
4. Prototype the app's output choices and permitted size/quality tradeoffs against real capability data; integrate the same core image job, then the broad-media path.
5. Validate libvips codecs, qpdf/PDF fidelity, optional Pandoc and LibreOffice packaging, and table export semantics. Publish only verified directions.
6. Validate local OCR API availability, then explicit provider consent, credentials, costs and reviewable transcription/extraction outputs. No provider account or paid API request is needed for the current work.

Each result should identify source revision, toolchain, OS/architecture, engine build, fixture provenance, command, checked invariants and limitations. Keep personal paths and hardware identifiers out of public evidence. Release requires clean-Mac pack installation, sandbox/signing verification, safety tests and dependency compliance in addition to successful codec probes.

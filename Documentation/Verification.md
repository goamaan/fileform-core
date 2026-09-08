# Verification evidence

September 8, 2026, local arm64/macOS 26.2, Xcode 26.2 / Swift 6.2.3.

- Real fixture tests cover image conversion, original preservation, transparency choice, explicit resizing, all eight orientation dimension transforms, changed input, destination collision/rename, and cancellation.
- A truncated-JPEG fixture demonstrated that ImageIO can repair missing image data while reporting a completed decode. JPEG/PNG end-record validation was added so incomplete containers are rejected before conversion. This check is not a claim to detect every possible corrupt bitstream.
- Media tests build synthetic recordings and exercise WAV→FLAC→M4A, MKV→MP4 remux, bounded MP4 target size, audio extraction, WebM/Opus→WAV and impossible size constraints. Outputs are probed and completely decoded.
- PDF tests retain all pages' text, require explicit page selection for image/PDF export, and verify selected-page structure. A generated receipt is recognized with local OCR.
- Table tests cover quoted delimiters/newlines, Unicode/BOM, empty cells, malformed quoting, duplicate headers, nested JSON rejection and large numeric lexemes that must not be rounded through Double.
- Process tests exercise timeout and cancellation. A blocking Foundation `waitUntilExit` call was replaced with asynchronous termination tracking after a reproducible test hang.
- The native app was exercised with the same image and a bundled-media conversion. Its JPEG bytes matched the CLI output exactly on this machine; the video result retained H.264/AAC streams, dimensions and full duration. App evidence lives with the separate GUI project.

Run `swift test` and `Tools/smoke-cli.sh` for the current suite. Media tests require `Tools/build-media-pack.sh` first. CI runs the same source build and tests. A green local test is not proof of clean-machine install, notarization, minimum-OS support or complete malformed-input resilience.

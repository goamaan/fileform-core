# Initial ImageIO result

Date: September 8, 2026. Tool: `Tools/probe-imageio.swift` in the initial repository commit. Command: `swift Tools/probe-imageio.swift`.

Environment: macOS 26.2 (25C56), Apple Silicon, Xcode 26.2 (17C52), Swift 6.2.3.

The generated 32 × 24 opaque sRGB fixture passed PNG encoding/reopening, TIFF encoding/reopening, single-frame and dimension checks, and normalized decoded-pixel equality against the generated original. The PNG bytes remained unchanged. TIFF output was 6,438 bytes on this run; that size is not a cross-version expectation.

ImageIO reported WebP among readers but not writers. AVIF and HEIC appeared in both inventories; this does not establish successful encoding or fidelity for those formats. The full runtime inventory is emitted by the command rather than maintained as a static support promise.

The initial compile exposed missing `try` markers on throwing guard conditions; these were corrected before the successful run. No external media engine was downloaded or executed.

This probe does not establish alpha, EXIF orientation, HDR, metadata preservation, damaged-input handling, cancellation, no-clobber finalization, or any minimum-OS guarantee. It is a feasibility measurement, not the production file-safety pipeline.

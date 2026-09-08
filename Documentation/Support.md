# Supported routes and current limits

Development verification: Apple Silicon, macOS 26.2, Xcode 26.2 / Swift 6.2.3. The macOS 14 deployment target is not yet a verified minimum-OS promise.

| Input family | Implemented outputs/actions | Current boundary |
|---|---|---|
| Still images readable by ImageIO | JPEG, PNG, TIFF; resize; JPEG quality search; make smaller; fit a byte limit | 8-bit SDR, one frame, at most 80 MP / 512 MB. JPEG/PNG require complete end records. Motion-photo attachments, animation, HDR and high-bit-depth preservation are not available |
| Media with the verified FFmpeg pack | MP4/MOV H.264 video; M4A/AAC, WAV/16-bit PCM, FLAC audio; audio extraction; remux when compatible; bounded target-size attempts | Maximum six-hour duration. Video outputs require one video/at most one audio track, square pixels and supported SDR properties. Explicit resizing for odd dimensions. Audio extraction can ignore unsupported video properties; multi-audio selection is not implemented |
| Unencrypted PDFs | Text from all pages or an explicit page, selected-page image or PDF export | At most 512 MB / 1,000 pages; text extraction up to 100 pages at once. Multi-page image/PDF export requires an explicit page. Signatures, interactive behavior and full layout preservation are not promised |
| Still image / scanned PDF | Local OCR to TXT | Review recognized text, numbers and reading order; no semantic-accuracy guarantee |
| CSV / TSV / flat JSON tables | Conversion between the other table formats | UTF-8, 8 MB, 100,000 rows, 1,000 columns. Unique non-empty headers and consistent column sets. JSON numbers retain their lexical precision when exported; JSON null becomes an empty CSV/TSV cell. CSV/TSV-to-JSON cells are strings |

Actual readers and writers remain directional. The ImageIO probe inventories runtime identifiers; it is not an advertised format matrix. Future HEIC/AVIF/WebP output, broader codec/publishing/Office packs and BYOK AI must pass their own build/packaging and fixture gates before being exposed.

Compression may produce no useful reduction; in that case the candidate is removed and `not_smaller` is returned. Lossless output formats can be larger than the source. Conversion never means arbitrary every-to-every semantic transformation.

Image exports currently normalize to sRGB and remove descriptive metadata; transparency removal requires an explicit background. The CLI and GUI share these decisions. Native image/document calls check cancellation between bounded steps; they are not yet isolated into a separate crash-resistant native worker. This remains a release-hardening task.

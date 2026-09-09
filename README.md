# Fileform Core

Convert, extract, resize and prepare files on your Mac. This is the public engine and full command-line interface behind Fileform.

**Development build.** Real image, media, PDF/OCR and table workflows are implemented and tested. This is not a customer-ready release or a promise that every file format is supported.

## Build and test

Use Xcode 26.2 / Swift 6.2.3 on macOS. The deployment target is macOS 14; local verification currently uses Apple Silicon and macOS 26.2.

```sh
swift build
swift test
swift run fileform --help
Tools/smoke-cli.sh
```

Media integration tests run when the pinned media pack exists. Build it from verified upstream source with Xcode's toolchain, Make and GnuPG:

```sh
Tools/build-media-pack.sh
export FILEFORM_MEDIA_PACK="$PWD/Artifacts/MediaPack"
swift test
```

The builder checks the source SHA-256 and upstream signing-key fingerprint. Its FFmpeg build has only local `file` and `pipe` protocols, with no GPL/nonfree configuration. This is a development build recipe; final signed distribution is a separate gate. Customers will not need Homebrew.

## Use the CLI

```sh
fileform inspect photo.png --json
fileform capabilities --input photo.png --json
fileform convert photo.png --to jpeg --output photo.jpg
fileform fit photo.png --to jpeg --max-bytes 500000 --minimum-quality 0.4
fileform convert transparent.png --to jpeg --background white
fileform convert recording.mkv --to mp4 --output ready.mp4
fileform convert recording.mkv --to m4a --output audio.m4a
fileform media trim recording.wav --to wav --start 1 --end 3 --output excerpt.wav --json
fileform media trim recording.mp4 --to mp4 --start 1.35 --end 3.57 --mode copy --output excerpt.mp4 --dry-run --json
fileform convert scan.png --to txt --output scan.txt
fileform convert document.pdf --to png --page 2 --output page-2.png
fileform convert table.csv --to json --output table.json
fileform convert photo.png --to jpeg --dry-run --json
```

Use `.build/debug/fileform` or `swift run fileform` before installing the executable. `--media-pack` or `FILEFORM_MEDIA_PACK` selects a verified local pack; a packaged CLI also discovers an adjacent `MediaPack` directory. No automatic cloud fallback, account, activation or API key is required for these operations.

Current outputs include JPEG/PNG/TIFF, MP4/MOV/M4A/WAV/FLAC with the media pack, [MP3](Documentation/MP3-output.md) with its encoder-enabled pack, PDF page/image/text operations and [embedded-image extraction](Documentation/PDF-embedded-images.md), local OCR, and CSV/TSV/flat-JSON tables. See [supported routes and limits](Documentation/Support.md).

## File safety and result contracts

Originals are never overwritten. Work goes to a job-owned temporary directory on the destination filesystem. Encoded outputs are reopened and checked before an exclusive atomic rename. A racing destination is retained; `--collision rename` chooses another name. Cancellation removes owned partial files after subprocess termination.

Fit-size success requires the complete final file at or below the exact byte limit. An infeasible request fails without publishing a best-effort candidate. Media verification checks duration, streams, channels/sample rate and a complete decode. OCR and lossy conversions still require appropriate human review.

`--json` writes a terminal report to stdout; progress stays on stderr. Exit codes: `0` completed (including `not_smaller`), `2` invalid job options, `3` unsupported/unavailable engine, `4` size target unmet, `5` I/O/collision/input changed, `6` engine/verification/resource failure, `130` cancellation. Argument-parser syntax errors use its standard `64` exit status. JSON serialization is a development contract with schema version 1.

## Free engine, paid Mac app

The engine and full CLI are Apache-2.0. Implemented formats, quality, verification, batch coordination and local transforms are not gated on payment. Optional BYOK provider adapters are planned for the open engine as well.

The separate proprietary Fileform app adds native interaction, visual workflows, integrations, app distribution and purchase support. Provider usage charges will remain separate from the app purchase.

See [architecture](Documentation/Architecture.md), [dependency policy](Documentation/Dependencies.md), [contribution guidance](CONTRIBUTING.md), [LICENSE](LICENSE) and [NOTICE](NOTICE). Third-party components retain their own licenses; the core license does not grant rights to proprietary GUI or brand assets.

Direct media URLs can be looked up and saved through the shared verified fetch adapter. See [direct fetch](Documentation/Direct-fetch.md) for CLI syntax, source binding, limits and network behavior. Web-page extraction and service coverage are separate capabilities.

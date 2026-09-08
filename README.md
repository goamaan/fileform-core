# Amend Core

The open-source foundation for Amend, a macOS file converter and compressor.

**Status: feasibility stage.** This repository currently contains an ImageIO probe and architecture/licensing decisions. The conversion library and `amend` CLI are planned, not implemented. No format support or production readiness is claimed.

## Free engine, paid app

The engine and complete CLI are Apache-2.0. Implemented conversions, compression, size targeting, batch execution, verification, preview generation, local OCR and optional BYOK provider adapters belong here. No license key, account, conversion quota or paid quality tier belongs in the engine.

Amend for Mac is a separate proprietary paid GUI. It adds native interaction, visual batch management, comparisons, integrations, signed app updates and purchase support. Provider usage charges are separate from the app purchase; AI transformations must require explicit upload/cost authorization.

## Run the first probe

On a Mac with Xcode's Swift toolchain selected:

```sh
swift Tools/probe-imageio.swift
```

It reports ImageIO reader/writer identifiers separately, generates a synthetic opaque sRGB image, encodes PNG, decodes it, writes TIFF, and checks type, dimensions and decoded pixels. Files live in a fresh temporary directory removed on exit. JSON goes to stdout; failures go to stderr with a nonzero exit status. It does not read user files or access the network.

Verified locally with Xcode 26.2 / Swift 6.2.3 on macOS 26.2, arm64. Other OS/hardware combinations remain untested. Runtime format identifiers are not verified conversion routes.

## Development direction

See [architecture](Documentation/Architecture.md), [dependency policy](Documentation/Dependencies.md), and [feasibility gates](Documentation/Feasibility.md). The next step is a safe image job through the shared library and CLI plus a reproducible broad-media engine spike.

See [LICENSE](LICENSE) and [NOTICE](NOTICE). Third-party components retain their own licenses. Apache-2.0 does not grant rights to the proprietary GUI or brand assets.

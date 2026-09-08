# Open-source boundary

This is the public Apache-2.0 engine/CLI repository. Never add private app code, commercial plans, billing integration, proprietary artwork, signing credentials or customer data.

Keep conversion, planning, queue/cancellation, verification, preview generation, pack management, local OCR and provider adapters usable from the open CLI. No GUI-only engine improvements, entitlement checks, SwiftUI imports or implicit cloud fallback in the shared core. Shared file-permission and credential primitives may live here; GUI consent presentation belongs in the app, with equivalent explicit CLI policies.

Only claim routes verified with the actual engine build. Preserve originals and finalize only verified outputs without clobbering existing files. Treat files as untrusted. Record dependency versions, build flags, licenses and distribution requirements before adding binaries.

Read Documentation/Architecture.md and Documentation/Dependencies.md before changing module or distribution boundaries. Scale verification to the change; the current probe runs with `swift Tools/probe-imageio.swift`.

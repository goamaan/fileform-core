# Shared engine boundary

Decision: September 8, 2026. The domain, shared engine, adapters and CLI are implemented; the interfaces are still in development.

```text
Native app (private)             fileform CLI (public)
          \                      /
              FileformCore (public)
              /              \
     FileformDomain          Adapter interfaces
                         /        |        \
                  Apple APIs  engine packs  AI providers
```

`FileformDomain` owns immutable inspection, capabilities, requests, plans, events, results and structured failures. It has no UI, commerce or network dependency.

`FileformCore` owns job coordination, resource policies, cancellation, safe temporary outputs and verification/finalization. Adapters own engine-specific options, execution, progress and validation. An explicit provider adapter may perform a user-authorized network operation; ordinary local conversion never silently switches to it.

The CLI owns terminal interaction and machine-readable contracts. The GUI owns SwiftUI/AppKit presentation, drag/drop, native previews, permission/consent presentation, visual history, billing and signed app updates. Reusable bookmark, Keychain and worker infrastructure belongs in public targets when the CLI or engine needs it. Neither app activation nor GUI persistence is a prerequisite to library use.

Inspection, output choices, target-size solving, preview generation, reusable presets, batch execution, pack downloading/verification and AI transformations stay public. Visual preset editing, comparisons, Finder integrations and GUI queue/history presentation may stay private. Underlying conversion behavior must not diverge between clients.

Engine packs are independently licensed, versioned dependencies. The public CLI can acquire the same supported packs without a paid-app entitlement. Pack manifests and build recipes should be public; signing private keys are always outside source control. A download is not an exemption from redistribution obligations.

The private app will consume a pinned core revision, then a versioned package release when available. Local development will use a sibling package override. Do not copy shared sources into the app or require access to the private repo to build public code. SwiftPM exports FileformCore and FileformDomain. The CLI uses the same ConversionEngine and plans.

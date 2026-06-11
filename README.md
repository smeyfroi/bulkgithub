# BulkGitHub

A native macOS workbench for finding — and later bulk-updating — repositories
across a GitHub organisation. You describe what you want in natural language;
an LLM writes a **TypeScript script** against a small, typed host API; the app
type-checks the script, shows it for review, and executes it in a sandboxed
JavaScriptCore context wired to capability handles (check scripts get a
read-only handle — the write surface does not exist on it).

![The BulkGitHub workbench: prompt, generated script, per-repo results, and evidence](Screenshot.png)

- Architecture and roadmap: [plans/native-macos-bulkgithub-app-plan-v2.md](plans/native-macos-bulkgithub-app-plan-v2.md)
- Runtime decision record: [decisions/0001-javascriptcore-as-embedded-script-runtime.md](decisions/0001-javascriptcore-as-embedded-script-runtime.md)
- Host API contract: [Sources/BulkGitHubKit/Resources/bulkgh.d.ts](Sources/BulkGitHubKit/Resources/bulkgh.d.ts)

## Build, test, run

Requires Xcode 26+ (Swift 6.2). All engine/model code lives in the SwiftPM
package; `BulkGitHub.xcodeproj` adds the native app shell (run/debug, asset
catalog icon, signing) and consumes the package locally. The project is
generated from [project.yml](project.yml) — edit that, not the pbxproj.

```sh
open BulkGitHub.xcodeproj      # app development (scheme: BulkGitHubApp)
xcodegen generate              # regenerate the project after editing project.yml

swift build                    # CLI build (CI uses this)
swift test                     # engine, validation, golden-recipe, support tests
swift run BulkGitHub           # run the app without Xcode (dev mode, no bundle)

swift Scripts/generate_icon.swift   # regenerate icon (icns + asset catalog) from Assets/icon-source.jpg
./Scripts/make_app.sh               # CLI release build → dist/BulkGitHub.app (ad-hoc signed)
```

The app launches in **fixture mode** with a **mock LLM** — the full
generate → type-check → review → run loop works offline against a canned
7-repo organisation. Flip to live GitHub / Anthropic in Settings (⌘,) once
credentials are stored (Keychain only; scripts can never read them).

## Layout

| Path | What it is |
|---|---|
| `Sources/BulkGitHubKit` | Library: models, GitHub clients (fixture + live), JSC script engine, capability handles, validation pipeline (lint → tsc → transpile → meta), LLM clients, Keychain, persistence |
| `Sources/BulkGitHub` | SwiftUI app: three-pane workbench, script editor, results table, console, Settings |
| `Sources/BulkGitHubKit/Resources` | `bulkgh.d.ts` (the contract), golden recipe, bundled TypeScript compiler + ES libs |
| `Tests/BulkGitHubKitTests` | Host-bridge contract tests, tsc-in-JSC spike tests, golden-recipe end-to-end, persistence |
| `plans/`, `decisions/` | Plan v2 (current), superseded v1, ADR 0001 |

## Phase 1 status (per plan v2)

- [x] SwiftPM scaffold, SwiftUI shell, app icon
- [x] Settings window with Keychain-backed credentials + connection tests
- [x] Core models (jobs, results, evidence, audit events, settings)
- [x] JSC engine: promise bridging, watchdog, cancellation, concurrency limiter
- [x] Read-only capability handle (`gh`/`job`/`parse`); evidence-receipt rule enforced
- [x] `bulkgh.d.ts` v1 (check-phase surface)
- [x] Validation pipeline incl. tsc-in-JSC; golden recipe; fixture GitHub client
- [x] Mock LLM (offline) + Anthropic client (live generation, off by default)
- [x] Persistence and restore-on-launch
- [x] Tests; CI + release workflow skeletons
- [ ] Live GitHub/Anthropic exercised end-to-end (deliberately deferred)

Later phases (dry-run updates, guarded writes, merge/cancel) are specified in
plan v2 and not yet implemented.

## License

Copyright © 2026 Steve Meyfroidt.

BulkGitHub is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full text.

The bundled TypeScript compiler (`Sources/BulkGitHubKit/Resources/TypeScript/`)
is Copyright Microsoft Corporation, Apache License 2.0. App icon artwork by
Steve Meyfroidt (`Assets/icon-source.jpg`).

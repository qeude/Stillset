# Stillset agent notes

## Product contract

- Keep video processing and screenshot export local to the Mac.
- Prefer recall over precision: retain meaningful pauses, scroll positions, and repeat visits as separate timeline occurrences.
- Use proxy frames for analysis; export PNGs from the original video at the selected timestamps.
- Treat visual similarity as evidence for review, never as permission to erase a candidate.

## Project layout

- `App/` owns the native app entry point and scene commands.
- `Packages/Core/` owns video decoding, analysis, models, and PNG export. Keep it independent of SwiftUI.
- `Packages/Features/` owns app state and SwiftUI screens, grouped under `RootFeature`, `ImportFeature`, `ResultsFeature`, and `TimelineFeature`.
- The checked-in `Stillset.xcodeproj` is the native project. Maintain it directly; local package manifests define the two package dependency graphs.

## Working in this repository

- Read the files relevant to the requested change. Use `README.md` for the current user workflow and analysis behavior; consult package manifests when changing package dependencies or targets.
- Keep analysis deterministic and preserve existing occurrences unless the requested behavior clearly changes that policy.
- For analysis or export changes, run `swift test --package-path Packages/Core`; the suite uses local recordings and temporary output. Fix regressions caused by the change before reporting completion.
- For Xcode builds, launches, and project inspection, use the Xcode MCP when available. Use `BuildProject` for compile-only work and call `StopProject` before each `RunProject`. Xcode and the shell fallback share `dist/Stillset.app`; keep `PRODUCT_BUNDLE_IDENTIFIER` as `com.qeude.stillset`. Use the CLI only when the MCP is unavailable or cannot perform the requested operation.
- Local builds use ad-hoc signing. Select a development team only when signing or distribution is part of the requested change.
- CLI compile-only fallback: `xcodebuild -project Stillset.xcodeproj -scheme Stillset -configuration Debug -derivedDataPath .build/Xcode CODE_SIGNING_ALLOWED=NO build`.
- Shell launch fallback: `./script/build_and_run.sh` builds and launches the app.

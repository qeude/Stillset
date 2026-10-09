# Stillset

Stillset turns `.mov` and `.mp4` screen recordings into representative screenshots. Video processing, screen recognition and full-resolution PNG export stay on your Mac.

It retains pauses, scroll stops and repeat visits. The **Uniques** view groups equivalent screen states for review; **Toutes** restores every capture. Uncertain matches remain separate, and grouping never deletes a capture.

## Requirements

- macOS 27 or later.
- Xcode 27 or later, with its command-line tools selected.
- Apple Intelligence enabled on a supported Mac only if you want optional AI refinement. Automatic analysis uses Vision and local image comparisons.

## Build and run

Open `Stillset.xcodeproj` in Xcode, select the **Stillset** scheme and **My Mac**, then run. Or build and launch in Release from the terminal:

```sh
./script/build_and_run.sh
```

Both use `dist/Stillset.app`. Local builds use ad-hoc signing and require no development team. `./script/build_and_run.sh --verify` also checks that the app process starts.

## Use

1. Drop a recording into the window or choose **Ouvrir…**. Analysis starts immediately. Captures appear as finalized pauses are exported, while the rest of the recording is still decoded.
2. Review the full-resolution captures in the timeline. Switch between **Uniques** and **Toutes**. Choose **Par écran** to gather captures under each detected screen name, or **Chronologie** to follow the recording. Groups follow first appearance; captures within each group stay chronological.
3. Click to select, Command-click to add captures, Shift-click to select a range, or press **⌘A** to select all visible captures. Arrow keys move through the timeline.
4. Drag the selection or press **⌘C** to copy its staged PNG files in recording order. Use **Exporter…** or **⌘S** to save selected visible captures in the current timeline order. SAVE assigns consecutive numbers and safe screen names, such as `001_compte.png`. **Chronologie** always saves into one folder. **Par écran** also uses one folder by default, with groups in first-appearance order and captures chronological within each group. Existing destination files are never overwritten.

Open **Stillset → Réglages…** (**⌘,**) to choose **Uniques / Toutes** and **Chronologie / Par écran** defaults for the next recording. Settings do not change the current recording or selection; timeline buttons apply only to that recording. For the next **Par écran** export, Settings also offers **Un dossier par écran**, for example `001_compte/001_compte.png`. Distinct screens keep separate folders even when their names match, and unclassified captures use **À identifier**. You can save committed captures while initial organization or AI refinement continues. Export freezes the selected captures, names and layout before opening the destination chooser. Analysis and saving have separate progress and cancel controls. A new recording can replace staging after analysis and saving finish. Saved PNGs are independent copies of the original-resolution bytes.

Automatic analysis finishes without Foundation Models requests. **Affiner avec l’IA** optionally refines ambiguous names and groups while navigation and export remain available. **Arrêter l’affinage** keeps the current results.

Successful OCR and comparison samples are reused for the current recording, including across local analysis and AI refinement. Results are held for the current session. Recognition and grouping are experimental; unfamiliar layouts may require manual review.

## Development

- `App/`: native app entry point and commands.
- `Packages/Core/`: decoding, analysis, models and PNG export, independent of SwiftUI.
- `Packages/Features/`: app state and SwiftUI screens.
- `Stillset.xcodeproj`: native project using both local packages.

Run the automated suites:

```sh
swift test --package-path Packages/Core
swift test --package-path Packages/Features
```

Tests generate synthetic inputs and do not need private recordings or an available Apple Intelligence model. GitHub Actions builds the app and runs both suites on the macOS 27/Xcode 27 preview runner. See [testing and profiling](docs/testing.md) for optional checks and [analysis internals](docs/analysis.md) for the matching policy.

## License

[MIT](LICENSE).

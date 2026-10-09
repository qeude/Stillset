# Testing and profiling

## Automated tests

Run both packages on macOS 27 with Xcode 27 selected:

```sh
swift test --package-path Packages/Core
swift test --package-path Packages/Features
```

Core tests cover motion and stability detection, representative frame selection, original-resolution export, catalog caching, error handling and local matching. The synthetic recording includes two scroll stops, navigation and a repeat visit. It can be generated when the checked-in fixture is absent.

`LocalPickerEvidenceTests` supplies synthetic recognized labels and pixel buffers to the local matcher, without Foundation Models. It checks small scrolls with changed glyph pixels, selection controls on either side of the labels, changed selections, changed option values and changes in the fixed header. These unit tests cover matching after OCR; they do not measure Vision recognition accuracy. No personal screenshots are included. Feature tests cover selection order, navigation, and dragging in the unique-screen view. Deterministic gates exercise the real recording and original PNG encoder to verify decode/export overlap, immediate first-PNG publication, bounded four-state batches with concurrent encoders, chronological publication, EOF tail without duplicate export, cancellation drainage, and error propagation. Save tests pause native organization and copy actual committed PNGs, checking frozen plans, panel reentrancy, independent cancellation, and surviving source files. Evidence tests check prepared-work adoption, the two-worker limit, one 800-pixel thumbnail per extraction, local-to-AI-to-local reuse, aliases, changed bytes, failed OCR retries, and known-empty title fallback. Real Vision parity tests run on generated images and the local recording.

Run a narrow regression while working:

```sh
swift test --package-path Packages/Core --filter LocalPickerEvidenceTests
```

Tests that need private captures or a local model are disabled unless their environment variables are provided. A passing default suite does not imply those optional checks ran.

The retry regression supplies an already recognized title so it does not require Vision OCR on the hosted runner. The concurrency regression uses explicit completion gates rather than elapsed time to check slot refilling and result order.

## CI

[The workflow](../.github/workflows/ci.yml) runs on pushes, pull requests and manual dispatch. It runs both package suites and compiles the app with signing disabled.

The `xcode-27` runner uses macOS 27 and is currently a public preview. `DEVELOPER_DIR` selects Xcode 27.0 explicitly. Runner availability and installed Xcode versions can change; consult [GitHub's runner image documentation](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) before updating the label or toolchain. `macos-latest` is not a substitute unless it provides both macOS 27 and the required SDK.

## Local performance checks

Supply your own recording outside the repository:

```sh
STILLSET_PROFILE_PIPELINE=1 \
STILLSET_PROFILE_LOCAL_ONLY=1 \
STILLSET_PROFILE_VIDEO=/path/to/recording.mp4 \
swift test -c release --package-path Packages/Core --filter profileLocalRecordingAndCachedCatalog
```

The profiling test requires both `STILLSET_PROFILE_PIPELINE=1` and `STILLSET_PROFILE_VIDEO`. Omit `STILLSET_PROFILE_LOCAL_ONLY` to include optional model refinement. It reports decode, export, catalog and cache timings. Timings depend on recording length, resolution and system load. The latest local baseline on a private 29-capture recording was approximately 8.3 seconds in Release for the automatic pipeline, excluding AI refinement; this is not a universal performance guarantee.

To check a catalog against the ten-second target, create a file with one absolute PNG path per line:

```sh
STILLSET_TEST_FAST_CATALOG_LIST=/path/to/ordered-png-paths.txt \
swift test --package-path Packages/Core --filter localCatalogIsReadyWithinTenSeconds
```

Private recordings and screenshots should stay outside the repository. The original iPhone profiling recordings are not distributed with Stillset.

## Optional real-capture and model checks

These require user-supplied captures. They supplement the portable synthetic regressions.

| Environment variable | Input / purpose |
| --- | --- |
| `STILLSET_TEST_LOCAL_MODEL=1` | Enable the generated-screen hybrid naming check with Apple Intelligence available. |
| `STILLSET_TEST_IMAGE_DIRECTORY` | Directory with `005_compte.png`, `006_compte.png` and `001_kilometrage.png` through `003_kilometrage.png`; account differences and mileage scrolls. |
| `STILLSET_TEST_MILEAGE_PAIR_DIRECTORY` | Directory with `018_choix-de-kilometrage.png` and `020_choix-de-kilometrage.png`; local sticky-header mileage scroll regression. |
| `STILLSET_TEST_FRONTMOST_DIRECTORY` | Directory with `001_picker.png`, `003_picker.png`, `006_form.png`, `008_form.png`; foremost picker and repeated partially filled form. |
| `STILLSET_TEST_SCROLL_DIRECTORY` | Directory with captures whose filenames start with `014_00-`, `015_00-`, `016_00-`; year-picker scrolls. |

For example:

```sh
STILLSET_TEST_MILEAGE_PAIR_DIRECTORY=/path/to/captures \
swift test --package-path Packages/Core --filter mileageScrollGroupsLocallyWithoutFoundationModels
```

# Contributing to Stillset

Bug reports, fixes, and focused improvements are welcome. Open an issue before starting a large change so we can agree on the approach.

## Build and test

You need macOS 27 or later and Xcode 27 or later. See [Get started](README.md#get-started) to build and run the app.

Run both suites before opening a pull request:

```sh
swift test --package-path Packages/Core
swift test --package-path Packages/Features
```

[Testing and profiling](docs/testing.md) describes the optional checks.

## Guidelines

- Keep processing local. Stillset must not upload recordings, screenshots, or analysis results.
- Never commit real screen recordings or screenshots. They can contain personal data. Tests use synthetic inputs and the checked-in fixture.
- Add every user-facing string to the string catalogs in English and French.
- Keep `Packages/Core` independent of SwiftUI.
- Write commit messages and pull request titles as [Conventional Commits](https://www.conventionalcommits.org/), such as `fix: keep selection after export`.

## Pull requests

Describe what changes for people using the app and how you tested it. Include a screenshot or a short recording for visual changes, made with sample content only.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

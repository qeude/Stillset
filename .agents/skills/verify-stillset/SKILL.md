---
name: verify-stillset
description: Verify Stillset user workflows in the native macOS app, including import, timeline arrival and automatic grouping, selection, export, and settings. Capture real UI evidence and distinguish functional results from animation proof.
---

# Verify Stillset

Use this skill to exercise the real app. Read [the feature index](features/README.md), then only the map relevant to the requested behavior. Keep processing and evidence local. Tests complement UI evidence; they do not replace it.

## Launch

Work from the repository root. Prepare an isolated evidence directory:

```sh
.agents/skills/verify-stillset/scripts/verify.py prepare
```

Retain the printed absolute directory as RUN. Optionally pass `--video /absolute/path/to/recording.mp4`. The default checked-in three-second fixture verifies import and selection; it cannot prove semantic screen grouping. Never assume a private video exists, copy one into the repository, or change the golden fixture.

Call Xcode MCP `XcodeListWorkspaces`, match this checkout's `Stillset.xcodeproj`, and retain its returned identifier. Call `StopProject` before `RunProject` only for a verification instance you own. If another person's instance is active, leave it alone and report the shared-instance blocker. Call `RunProject` with that identifier and `attachDebugger: false`. Retain its PID and launch session reference, then run:

```sh
.agents/skills/verify-stillset/scripts/verify.py record-launch RUN --pid PID --session SESSION
```

Replace RUN, PID, and SESSION with the actual returned values; do not copy an old identifier. If Xcode MCP is unavailable, use the repository's documented compile-only CLI fallback and explicitly launch this checkout's bundle. Do not use `script/build_and_run.sh` for isolation: it stops every process named Stillset.

## Doctor

```sh
.agents/skills/verify-stillset/scripts/verify.py doctor RUN
```

This checks the exact process path and start identity, plus the full bundle hash. A failure means stop driving and resolve the mismatched or rebuilt instance. Bind CUA to the absolute `dist/Stillset.app` path from `run.json`, rather than the bundle identifier shared by other checkouts:

```js
var app = await cua.getApp('/absolute/checkout/dist/Stillset.app');
```

Check the actual window and readiness in its accessibility tree. A fresh launch shows the import landing screen and **Ouvrir…**. Record a different starting state explicitly. App preferences, clipboard and native file panels are shared; do not drive two instances simultaneously.

## Drive

Use `cua_repl` for every native UI action. Derive indexes from the latest `app.getAXState()`; refresh after actions. After a screenshot-only observation, request `getAXState({disableDiffing: true})` before reusing indexes. Native menus may require Return after selecting an item.

For import, press `super+o`, inspect the file panel, press `super+shift+g`, paste the absolute video path from `run.json`, and press Return. Inspect the new tree, then activate the observed Open button. Do not assume panel indexes or fixed delays. Follow the chosen feature map and verify the resulting state, rather than merely logging clicks.

## Evidence

Capture the app directly; no Screenshot utility or recorder is required for a static visual check:

```js
await app.getScreenshot();
```

The image is emitted into the verification conversation. Record that tool capture as evidence. Preserve the native AX text alongside it in RUN/evidence using `save-ax RUN --name state.txt` with the observed text on standard input. Record actions with `append-action RUN --feature FEATURE --entry ENTRY --action ACTION --observed OBSERVED`.

Write RUN/evidence/verdict.md with the fixture, launch identity, entry point, actual actions, expected and observed results, evidence references, and pass/fail/not-run verdicts. Keep private recordings outside the repository. Persist screenshot bytes only when the active runtime documents a supported file-writing method; do not invent one or open another screenshot application merely to obtain a still image.

For animation claims, capture consecutive timestamped frames or a real recording covering placeholder arrival and automatic grouping while analysis runs. A screenshot, AX change, transaction log, or passing test cannot prove motion or 120 fps. Check manual filter motion separately. If the available tools cannot capture that sequence, mark motion **not run**, identify the limitation, and still verify the functional path. Respect Reduce Motion and restore any preferences you changed.

## Cleanup

```sh
.agents/skills/verify-stillset/scripts/verify.py cleanup RUN
```

The helper stops only the recorded PID after checking its original process identity, removes only run-owned scratch files, and retains evidence and metadata. Do not kill by process name or delete arbitrary temporary folders. Confirm evidence remains readable after cleanup. Preserve the user's inputs and exported files unless they were explicitly created as disposable verification outputs.

## Helpers

[scripts/verify.py](scripts/verify.py) uses only Python's standard library for run ownership, diagnosis, action logs, AX archival and cleanup. It never drives UI. Use `--help` for exact command arguments. The four [feature maps](features/README.md) describe user entry points and their limitations. After UI changes, use `/maintain-verification-skill` to reconcile those maps with the current app.

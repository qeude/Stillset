# Stillset feature proof map

Use this index to choose a user-visible path and gather evidence for it. The workflow and labels here are checked against the current [README](../../../../README.md) and app entry points. Keep these maps current whenever an entry point or visible behavior changes.

| Feature | User entry points | Map |
| --- | --- | --- |
| Import and queue | Drop recordings; Import screen **Ouvrir…**; toolbar **+**; **File → Ouvrir des enregistrements…** (⌘O); **File → Ajouter des vidéos à la session…** (⇧⌘O); per-video status and queue popover | [import-and-queue.md](import-and-queue.md) |
| Timeline and motion | Timeline; **Filtres** menu (**Uniques / Toutes**, **Chronologie / Par écran**); analysis arrival and session screen grouping | [timeline-motion.md](timeline-motion.md) |
| Selection and export | Timeline click / ⌘-click / ⇧-click / ⌘A; **Copier les captures** (⌘C); **Exporter…** or **Enregistrer les captures…** (⌘S); drag selection | [selection-and-export.md](selection-and-export.md) |
| Settings | **Stillset → Réglages…** (⌘,) | [settings.md](settings.md) |

## Evidence rules

Launch the native `com.stillflow.app` through the native Xcode MCP. Use `cua_repl` for every UI action and observation. Resolve the running app from its launch/run metadata, read `app.getAXState()`, and use only indexes freshly observed in that accessibility tree. Re-read the tree after state changes before clicking; native menu items may need Return after they open. Do not use browser locators or stale indexes.

For file selection, invoke the app's open command, press ⌘⇧G in the file panel, type the absolute video path, press Return, then inspect the new tree and click its current **Open** button index. Do not assume an old index remains valid.

Prepare evidence with the skill helper. `prepare` accepts an optional `--video`; without it, it uses the checked-in Core fixture. `record-launch RUN --pid PID --session SESSION` records the PID and session returned by the native MCP launch. `doctor RUN` is read-only. `append-action RUN --feature FEATURE --entry ENTRY --action ACTION --observed OBSERVED` records an observed action. Evidence belongs under `RUN/evidence`; AX text may also be saved there as a transcript. `cleanup RUN` may signal only the recorded run PID after checking its process identity; it must not delete evidence.

The checked-in Core fixture is about three seconds long and has no OCR-readable screen, so it cannot prove automatic OCR grouping. A grouping claim needs a suitable recording, optionally supplied as a video outside the repository; never assume a private recording path. To prove animation, capture actual video frames with consecutive timestamps that show the timeline's empty placeholder before captures arrive and the arrival afterward. Accessibility text, action logs, or unit tests alone do not prove motion. If no suitable recording is available, mark animation as not run. A canceled single-video import is still available as a focused queue-generation scenario.

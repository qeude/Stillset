# Using Stillset

[Back to the project overview](../README.md)

This guide uses the English interface labels. Stillset also supports French and follows the macOS app language preference, with English as the default and fallback language.

## Importing recordings

Drop one or more recordings into the window or choose **Open…** to select multiple files. Videos enter a local queue in import order, with at most two simultaneous analyses. The toolbar **+** and **File → Open Recordings…** (**⌘O**) show a new session immediately; its queued videos start once previous work has stopped; cancelling the chooser preserves the current session. Use **File → Add Videos to Session…** (**⇧⌘O**) to append recordings while retaining the current results. Waiting videos start when a slot is freed by a finished analysis or a drained cancellation. Captures appear as finalized pauses are exported, while the rest of each recording is still decoded.

## Browsing captures

Review every video in one timeline with one selection, focus, and set of filters. **Chronology** has video chapters in import order and captures in each recording’s local timestamp order, regardless of completion order. **By Screen** joins local screen categories across recordings only when the session catalog positively matches a state. Equal names alone keep separate groups. **Unique** shows the first occurrence of each matched state; **All** restores every occurrence. Different states in a joined screen family remain distinct. Background matching preserves selected or focused repeats until you explicitly apply a filter.

## Selecting captures

Click to select, Command-click to add captures, Shift-click to select a range, or press **⌘A** to select all visible captures. Arrow keys move through the timeline. Shift-arrow extends a range across videos. Pending captures cannot be selected. The preview and thumbnails show the video ordinal, source filename, attempt, and local timestamp.

## Exporting PNGs

Drag the selection or press **⌘C** to copy its staged PNG files in source chronology, with videos in import order. Use **Export…** or **⌘S** to save selected visible captures in the current timeline order. Saving assigns consecutive numbers and safe screen names, such as `001_account.png`. **Chronology** always saves into one folder. **By Screen** also uses one folder by default, with groups in first-appearance order and captures chronological within each group. Existing destination files are never overwritten.

## Cancellation, retries, and errors

Use **Cancel** on a running video to stop that video's analysis. Its partial captures remain available, and other videos continue. **Retry** appends a new labelled attempt and keeps the previous results and error. Only waiting videos can be removed with **Remove**. Invalid files and analysis errors stay visible in their rows and do not block subsequent videos. The status popover lists per-video progress, errors, cancellation, retry, and queued removal. Finishing a background analysis preserves the captures you are reviewing; ready captures remain exportable while another video analyzes.

## Settings and export folders

Open **Stillset → Settings…** (**⌘,**) to choose **Unique / All** and **Chronology / By Screen** defaults for the next session. Settings do not reset a live session’s filters or selection; timeline filters apply to the whole session. For the next **By Screen** export, Settings also offers **One Folder per Screen**, for example `001_account/001_account.png`. Distinct screens keep separate folders even when their names match, and unclassified captures use **Unidentified**. Export freezes the selected captures, names and layout before opening the destination chooser; background refinement can continue. Saved PNGs are independent copies of the original-resolution bytes.

## Recognition and optional AI refinement

Automatic per-video and session analysis finishes without Foundation Models requests. The session catalog analyzes immutable terminal PNG snapshots in source chronology with local contextual naming. **Refine with AI…** optionally refines ambiguous names and groups while navigation and export remain available. **Stop Refinement** keeps the last complete results. Refinement changes session metadata without renaming staged PNGs, and later automatic catalog updates retain accepted refinement evidence for unchanged captures.

Apple Intelligence must be enabled on a supported Mac to use optional AI refinement. Automatic analysis uses Vision and local image comparisons.

## Local analysis cache

Successful OCR and comparison samples are reused across local analysis and AI refinement. Recent completed analyses, including partial recognition diagnostics, are reused automatically for identical video content in the same app language. The local JSON cache contains metadata only, with no images, video copies, or file paths. It retains at most 50 entries for 30 days, within 10 MiB total and 1 MiB per entry. Larger analyses remain usable without caching. Every import recreates full-resolution PNGs from the original video. **Reanalyze** bypasses reuse and replaces cached metadata only after a successful fresh analysis. Successful optional AI refinement updates the cached metadata.

## Session lifetime

All imported videos and their staged PNGs are retained for the current app session. Sessions are not restored after relaunch.

## Reporting a problem

Choose **Help → Export Diagnostic…** to save technical diagnostics locally. The report excludes recordings, screenshots, recognized text, and personal file paths. Nothing is sent automatically. See [reporting a problem](diagnostics.md) for the contents, retention, and separate crash-report instructions.

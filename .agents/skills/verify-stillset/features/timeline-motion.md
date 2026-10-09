# Timeline and motion

## Sub-features

- Show captures from every video in one timeline, with video chapters in import order and captures ordered by each recording's local timestamps.
- Switch the session-wide view between **Uniques** and **Toutes**, and between **Chronologie** and **Par écran**.
- Show a pending video chapter before its first captures arrive, then populate it as analysis produces captures.
- Join screen categories across videos only when the catalog positively matches states. Equal names alone do not join them; grouping does not remove occurrences.

## How to get to it (user POV)

Import a recording to reach the results timeline. Use **Filtres** in the toolbar to choose **Uniques** or **Toutes** and **Chronologie** or **Par écran**. With multiple videos, the same timeline shows all imported videos. During analysis, a chapter can show status and **Aucune capture disponible** before thumbnails arrive. In **Par écran**, screen headings gather positively matched categories across recordings.

## Driving it with `cua_repl`

Launch through the native Xcode MCP. Resolve `com.stillflow.app` from launch metadata, then use only `cua_repl` and `app.getAXState()` for UI observation and interaction. Select controls through freshly observed native AX strings and indexes, and refresh the tree after every state change. Open **Filtres** and select its current **Uniques / Toutes** or **Chronologie / Par écran** option; native menu items may require Return after opening. Keep one video or multiple videos visible to show the relevant timeline chapters.

For arrival motion, use a recording that takes long enough to expose the empty chapter before captures appear. Record consecutive, timestamped video frames that visibly show that chapter before and after arrival; save them under `RUN/evidence`. AX output and the action log can accompany these frames but cannot establish animation by themselves. To show automatic grouping, use a recording with OCR-readable screens that actually produce catalog matches, select **Par écran**, and capture the resulting headings and occurrences. The default three-second fixture has no OCR-readable text and cannot support this proof.

## Gotchas

- The timeline is compact and horizontal; use its native accessibility scroll action or observed controls, and re-read AX state after paging.
- Pending captures cannot be selected. A chapter may remain visible with **Aucune capture disponible** while a video is still processing.
- **Uniques** changes visibility to the first occurrence of matched states. **Toutes** restores occurrences; it does not alter the stored captures.
- Manual filter choices are distinct from automatic OCR-based screen grouping. Do not treat switching **Uniques / Toutes** as evidence that catalog grouping succeeded.
- Similarity or same-name headings alone are not proof that screens joined. Capture the actual multi-video **Par écran** result.
- Mark motion as not run if no suitable recording can produce observable before-and-after frames. The short Core fixture is insufficient for automatic grouping proof.

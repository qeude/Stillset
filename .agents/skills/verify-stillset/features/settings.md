# Settings

## Sub-features

- Set the default capture filter (**Uniques** or **Toutes**) for the next session.
- Set the default timeline organization (**Chronologie** or **Par écran**) for the next session.
- Choose one destination folder or one folder per screen for the next **Par écran** export.
- Keep settings changes from resetting the live session's filters or selection.

## How to get to it (user POV)

Choose **Stillset → Réglages…** (⌘,) from the app menu. The grouped form contains **Captures**, **Organisation**, and **Export par écran** controls. The first two apply as defaults to a newly opened session. The export layout is used for a future **Par écran** export.

## Driving it with `cua_repl`

Launch the native app through the native Xcode MCP and resolve `com.stillflow.app` from run metadata. Use `cua_repl` only: inspect with `app.getAXState()`, select current native AX labels, and click only indexes freshly observed after reading that state. Open **Stillset → Réglages…** (or press ⌘,) and re-read the tree after the window opens. Change each picker by its visible accessibility label and current option, then read the tree again to confirm the selected value.

To verify that defaults affect the next session, note current-session filter state, change a setting, then open a replacement session using ⌘O and a suitable recording; inspect **Filtres** in the new session. For the folder setting, choose **Par écran**, select **Un dossier par écran**, and export to a reviewable destination; capture the visible saved folder structure. Do not claim an export-layout result from the picker alone.

## Gotchas

- Capture and organization defaults apply to the next session; changing them should not reset the live session's filters or selection.
- **Un dossier par écran** affects **Par écran** exports. **Chronologie** always saves into one folder.
- Screens with equal names can remain distinct when the catalog does not positively match them. Each retains a separate folder; unclassified captures use **À identifier**.
- Keep the proof focused on user-visible picker values and resulting session/export behavior. A settings window screenshot alone does not prove the next-session behavior.

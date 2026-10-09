# Selection and export

## Sub-features

- Select one capture, add captures with Command-click, select a range with Shift-click, or select all visible captures with ⌘A.
- Move focus with arrow keys; Shift-arrow extends a selection across videos.
- Drag selected captures or use **Copier les captures** (⌘C) to copy staged PNGs.
- Save selected visible captures with **Exporter…** or **Enregistrer les captures…** (⌘S), preserving current timeline order and the chosen export layout.
- Keep ready captures exportable while another video analyzes. Existing destination files are never overwritten.

## How to get to it (user POV)

Import a video and select a ready thumbnail in the timeline. Command-click adds another capture and Shift-click selects a range; ⌘A selects all visible captures. Use ⌘C or the File menu's **Copier les captures** command to copy. Use the toolbar **Exporter…** or ⌘S to choose a destination for saved PNG files. Timeline filters determine which captures are visible and therefore eligible for ⌘A and export.

## Driving it with `cua_repl`

Launch via the native Xcode MCP; resolve `com.stillflow.app` from run metadata. Observe the native accessibility tree with `app.getAXState()` and interact only through `cua_repl`; indexes must match strings in the most recently observed tree. Refresh the tree after selection changes and verify selected state before export. Use ⌘A only after ready captures are visible. For multi-selection, use the observed capture elements and modifier-click if the CUA API supports it, then confirm the selected values in fresh AX state.

Invoke export through the currently observed **Exporter…** button or ⌘S. In the destination panel, choose the folder through observed controls and confirm the current save/open action by its AX label and index. Capture the resulting filenames and folder structure as evidence. Test non-overwrite behavior by attempting an export where a destination filename already exists and verify the app's visible outcome without assuming the existing file changed. A `.png` file dropped onto the import screen is an invalid video case, not an export test.

## Gotchas

- Pending captures cannot be selected. Wait until the target capture is ready, then re-read AX state.
- ⌘A selects visible captures under the current filters. Use **Toutes** when the proof needs all occurrences.
- Drag and clipboard output use source chronology; saved output follows the current timeline order.
- **Chronologie** saves in one folder. **Par écran** uses one folder by default; Settings can enable one folder per screen. Unclassified captures use **À identifier**.
- Export freezes the selected captures, names, and layout before the destination chooser opens; later background refinement does not change that export.
- Existing destination files must not be overwritten. Confirm the visible result and preserve evidence from the run.

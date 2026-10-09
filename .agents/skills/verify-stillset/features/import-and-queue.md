# Import and queue

## Sub-features

- Start a session by dropping one or more recordings or choosing **Ouvrir…** from the empty import screen.
- Replace the current session with the toolbar **+** or **File → Ouvrir des enregistrements…** (⌘O). The chooser can select multiple videos; they appear in import order and no more than two analyze at once.
- Append videos with **File → Ajouter des vidéos à la session…** (⇧⌘O), preserving current results.
- Review progress, errors, cancellation, retry, and waiting-video removal. **Annuler** stops a running video and retains its partial captures; **Réessayer** adds a labelled attempt; **Retirer** is for waiting videos.
- Invalid files remain visible as errors without stopping later queue entries.

## How to get to it (user POV)

At launch, the empty screen offers **Ouvrir…** and accepts dropped recordings. With a session open, use the toolbar **+** / ⌘O to start a replacement session, or ⇧⌘O to append. For more than one video, open the **Vidéos de la session** status control to inspect per-video rows. A single video shows its **Annuler** or **Réessayer** control below the capture count while applicable.

## Driving it with `cua_repl`

Launch via the native Xcode MCP and resolve the app from run metadata using bundle `com.stillflow.app`. Get `app.getAXState()` and choose controls by their exact current native accessibility labels. After every click, menu action, or dialog transition, fetch a fresh tree and click only a currently observed index. Use `app.pressKey` for ⌘O, ⇧⌘O, and button/Return actions as appropriate. For the file panel, press ⌘⇧G, type the absolute video path, press Return, then re-read the tree and click its current **Open** button. For multi-video selection, repeat path entry only if the panel remains open and confirm the resulting selection before opening.

To observe the replacement-vs-append distinction, first load one video, then invoke each command in separate runs or repeatable states. Canceling the replacement chooser should leave the existing session in place. For the queue controls, load multiple videos and inspect the status popover; capture the row labels and available actions from the AX tree before using them. A cancellation test can use one video and **Annuler** without needing a multi-video recording.

## Gotchas

- ⌘O replaces the session; ⇧⌘O appends to it. A canceled chooser preserves the current session.
- The multi-video status popover appears only when the session has more than one video. Single-video progress and cancellation are shown below the count.
- Progress buttons and bars use the violet accent. Do not infer completion from color; read the row's status and progress text.
- A queued item can be removed; an active item can be canceled. Retry appends another attempt and preserves earlier output.
- A `.png` is not a valid video. Use it as a deliberate invalid-input case only; it should produce a visible row error while the app remains usable.
- Record process identity at launch. Cleanup is limited to the recorded app PID after confirming its identity; preserve the run and evidence directories.

# Report a problem

Describe what you expected, what happened, and the steps that reproduce the problem. Include the approximate time of the incident.

Choose **Help → Export Diagnostic…** to save a local JSON report. In French, choose **Aide → Exporter un diagnostic…**. Open the file in a text editor before sharing it. Stillset does not upload the report or send it to anyone.

The report contains app and macOS versions, operation identifiers, timestamps, and technical events such as analysis completion, cancellation, or a fixed error category. Operation identifiers are random and do not identify a recording or a device.

Diagnostics exclude videos, screenshots, recognized text, screen names, source paths, filenames, video hashes, account information, and raw system logs. The analysis cache is separate and is never attached to the report. Do not attach a recording or the analysis cache to a public issue.

Stillset keeps at most 256 diagnostic events within 256 KiB. Events older than seven days are removed when the journal is next read, updated, or exported. No cleanup runs while the app is closed. The journal records operation boundaries rather than every frame or interaction. A start without a completion event does not prove that the app crashed. A sudden termination can prevent the most recent event from being saved.

## Report a crash

If Stillset closes unexpectedly, macOS may create a crash report. Find Stillset under **Crash Reports** in Console. Crash reports are separate from Stillset's diagnostic export and can contain paths or other system information. Review a crash report before sharing it through a private support channel.

## Keep release symbols

For each distributed build, maintainers must retain the exact app and its matching `.dSYM` bundle with the release artifacts. Rebuilding the same source later does not recreate the matching crash symbols. Keep symbols outside the public diagnostic report.

Compare the UUIDs before archiving a build's symbols:

```sh
xcrun dwarfdump --uuid /path/to/Stillset.app/Contents/MacOS/Stillset
xcrun dwarfdump --uuid /path/to/Stillset.app.dSYM
```

Retain both artifacts under that build's version and UUID. Symbolicate a reported crash against its matching build. The [release workflow](releasing.md) checks that the UUIDs match and attaches the `.dSYM` archive to each GitHub release.

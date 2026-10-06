# Screen recording samples

`scroll-stops-navigation-return.mov` is a locally generated 128 × 192, 10 fps recording. It contains a home list, two separate scroll stops on that list, a details view, and a return to the original home appearance.

Expected stable occurrences (approximate seconds):

| Occurrence | Expected interval |
| --- | --- |
| Home at top | 0.0–0.4 |
| Home after first scroll stop | 0.8–1.2 |
| Home after second scroll stop | 1.6–2.0 |
| Details | 2.2–2.5 |
| Home after return | 2.7–3.0 |

The integration test calculates recall and precision from these intervals, exports all retained occurrences, and checks that PNGs keep the source dimensions. This fixture tests pipeline mechanics, not real iPhone codec variety or every sheet, keyboard, animation, and scroll style.

Real iPhone recordings are not distributed. Performance checks require an explicit `STILLSET_PROFILE_VIDEO` path to a recording outside the repository. See [testing and profiling](../../../../docs/testing.md).

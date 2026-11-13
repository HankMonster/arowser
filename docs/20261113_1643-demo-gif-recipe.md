# arowser screenshot-based demo GIF

Final: `demo.gif` — 800 × 800, 14.5 seconds, 12 fps, 1,714,146 bytes. Static overview: `poster.png`.

## Design

Three actual arowser windows illustrate the notify-user and show-info skills. All content and metrics are fictional and labeled demo data. A notification appears, a report opens, a change summary joins it, then the notification fades while the results remain. Screenshots are composited; animation does not claim to reproduce native window transitions.

All text is English; Maple Mono NF CN is used throughout. Only the windows themselves were captured, with transparent rounded corners. No desktop, Terminal, private paths, internal domains or other apps are present in the delivered GIF. Repository files and README remain unchanged.

## Render and capture

`create-scenes.py` uses the installed show-info renderer's `build_html()` with neutral metadata, and the notify-user card template with English demo content. Task-specific CSS lives in `scenes/`; the original skills are unchanged. The demo notification uses a dedicated id/owner, leaving the shared real notification untouched.

```sh
python3 /tmp/arowser-demo/create-scenes.py
AROWSER_OWNER=public-demo-gif arowser open /tmp/arowser-demo/scenes/report/index.html --id gif-report --title 'Benchmark report' --w 440 --h 560 --x 100 --y 150
AROWSER_OWNER=public-demo-gif arowser open /tmp/arowser-demo/scenes/summary/index.html --id gif-summary --title 'What changed' --w 292 --h 275 --x 580 --y 450
AROWSER_OWNER=public-demo-gif arowser open /tmp/arowser-demo/scenes/notify.html --id gif-notify --title 'Report ready' --float --w 292 --h 260 --x 580 --y 150
```

Read current macOS window numbers from CoreGraphics `CGWindowListCopyWindowInfo`; match owner arowser and the exact three titles. Window numbers are ephemeral. This take used 4770/4771/4772 respectively:

```sh
screencapture -x -o -l4770 /tmp/arowser-demo/screens/report.png
screencapture -x -o -l4771 /tmp/arowser-demo/screens/summary.png
screencapture -x -o -l4772 /tmp/arowser-demo/screens/notify.png
```

Captures are Retina RGBA: 880×1120, 584×550, 584×520. Window-id capture excludes other windows and preserves alpha. Inspect each screenshot before compositing; the first layout clipped footer metadata, fixed by removing redundant copy before recapturing.

## Compose and encode

`compose.py` uses Pillow to place the real screenshots over a fictional scrolling agent session on an 800×800 background, with shadows, captions and short ease-in transitions. It writes 174 PNG frames and `poster.png`. Timing: notice 0.2s, report 2.5s, summary 6.5s, notice dismiss 11.5s, fade/reset 14–14.5s.

```sh
python3 /tmp/arowser-demo/compose.py
FFMPEG=ffmpeg (any recent build; here: the binary bundled by imageio-ffmpeg)
"$FFMPEG" -hide_banner -loglevel error -y \
  -framerate 12 -i /tmp/arowser-demo/frames/%04d.png \
  -filter_complex 'split[a][b];[a]palettegen=max_colors=256[p];[b][p]paletteuse=dither=none:diff_mode=rectangle' \
  -loop 0 /tmp/arowser-demo/demo.gif
```

## Validation

- Inspected each actual window screenshot and the final 800px overview.
- Vision OCR output saved in `ocr-screens.txt`: report values, change summary, notification and all three metadata footers are present.
- Pillow verified dimensions, 174 frames, total duration 14,500 ms, and transparent capture corners.
- Metrics agree: build 42→28s is 33% less time (rounded); tests 18→12s; bundle 240→204KB. These are illustrative, not arowser benchmarks.
- Compositor window bounds: report (24,112)–(464,672), notice (484,112)–(776,372), summary (484,392)–(776,667); no overlap or clipping.

## Pitfalls

- Live desktop recording introduced unrelated Terminal UI and timing issues; that approach was abandoned after the user chose screenshot composition. Old takes were removed.
- Screenshot by window id avoids leaking background through desktop-region capture.
- Footer visibility must be checked on the screenshot; HTML source alone did not reveal clipping.

## Scrolling session revision

Requested by the user after viewing the initial version. The background is an entirely authored English session, labeled DEMO SESSION. No real conversation or terminal capture is used. Text scrolls slowly behind the unchanged real window screenshots; foreground content remains dominant. `demo.gif` and `demo-session.gif` are the current version. `demo-clean.gif`, `poster-clean.png`, and `compose-clean.py` preserve the plain-background variant for comparison. A 256-color palette without dithering keeps flat card backgrounds clean while controlling the animation size.

## Continuous visibility correction

The first session variant scrolled behind the cards but was obscured once all result windows appeared. The corrected canvas is 800×800, preserving card sizes and leaving an unobstructed session strip below them (y=690–756). New transcript lines are anchored near the bottom of the session viewport. The session no longer fades with the foreground windows at the loop end.

Validation reads the encoded GIF, crops the exposed session strip in all 174 frames, and confirms visible pixel changes in every one of the 173 adjacent frame pairs. Dimensions, duration and byte size are saved in `validation.json`. Actual screenshots, foreground cards and their positions remain unchanged.

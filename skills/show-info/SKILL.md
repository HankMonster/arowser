---
name: show-info
description: "Render agent results (tables, JSON, diffs, long output, charts) as markdown → HTML in an arowser window: use when terminal formatting is hostile or the output would scroll away, and when a task produces substantial results the agent may proactively open a window without being asked. Use when the user wants to see result artifacts, asks to 'show this in a window', the output deserves careful reading, or mentions show-info."
---

# show-info: result presentation window

The agent writes results as markdown; one command renders and displays them in an arowser window. Division of labor with notifications:

- Getting the user's attention (done / needs help / problem) → notify-user (shared window, overwrites, transient)
- **Result artifacts worth studying (tables/charts/long output) → this skill** (content-sized window, persistent, close with ⌘W)
- User away → the user's own away-notification channel

## Proactive display

When a task produces substantial results (comparison tables, charts, batch summaries — anything the terminal shows poorly) you may open a window **proactively**, without waiting to be asked. Still hold the line:

- Finish computing/verifying first (a closing action); the window's conclusions must agree with what you say in the conversation
- Lightweight conclusions that fit a sentence or two get answered in the conversation — no window
- Iterations of the same result reuse the same `--id`; don't chain new windows

## Content format

- Text/tables: native GFM; `DataFrame.to_markdown()` output works as-is
- Inline HTML is live: `<font color>`/`style`, `<mark>` emphasis, `<details>` to fold verbose detail
- Charts: ` ```echarts ` blocks whose body is an ECharts option JSON (inlined); chart height fixed at 320px
- Images: write local absolute paths (the script copies them next to index.html and rewrites to relative references); web/data URLs pass through

## Usage

```bash
command -v arowser >/dev/null || { echo "arowser missing — install/build it first (see the arowser skill)"; exit 1; }
python3 <skill-dir>/scripts/md2window.py <result.md> [--title T] [--id reuse-and-update] [--h height]
```

- Input is a markdown file path or `-` (stdin); `--raw` passes complete HTML through unchanged
- Title defaults to the first H1, else "Result"; width defaults to 460, height estimated from content (320–1400)
- The window opens at arowser's default level (normal, not floating, since 2026-11-13); artifacts land in `/tmp/show-info/<window-id>/` (index.html + resources) — one-shot presentation output

## Lifecycle

- Default: each run opens a new window (`info-<HHMMSS>`); refreshing the same result (progress updates) passes the same `--id` to update in place
- Never close a window the user opened; the user closes it with ⌘W via the fixed footer hint
- Later windows don't overwrite earlier ones — multiple artifacts coexist; ⌃⌥⌘L switches between them

## Boundaries

- All data is inlined into the HTML (WebKit blocks local `fetch`); resources (style.css/echarts.min.js/images) are referenced relatively from index.html's directory — never absolute paths
- For interactive on-demand data (pagination/lazy-load/drill-down): hand-write a directory (index.html at the root, data snapshots and regen scripts beside it, page fetches via relative URLs; refresh = rerun script + ⌘R) and use `arowser serve <dir>` for the URL, then `open` (or `open <dir> --serve` in one step): same directory is idempotent with the same URL, serve.json revives mounts across restarts, no-store caching — **serve directories are long-lived artifacts: keep them in a project-private location (not in Git), never /tmp** (periodic /tmp cleanup kills dashboards). Localhost only, no auth (never serve sensitive directories); full usage is in the arowser skill. Simple presentations stay on this skill's default file:// inline pipeline
- Smoke-testing the render pipeline must open a real window and visually check (screenshot or eyes) that charts/key text are visible — a source grep or an `arowser list` hit only proves the window opened, not that it rendered. Screenshot recipe: `arowser list --json` → take the window's x/y/w/h → `screencapture -R "x,y,w,h" <png>`. Served pages can add a machine smoke check: curl the page and data files for 200, and pass an in-page `<script>` through `node --check` to catch syntax-level white screens
- Presentation is a closing action: finish computing/verifying first; window content and in-conversation conclusions must match
- Updating echarts.min.js: take a 6.x build from an echarts distro (node_modules or CDN) and overwrite `assets/echarts.min.js`
- Tests live in `tests/` (unittest, no arowser dependency): `python3 -m unittest discover -s <skill-dir>/tests`

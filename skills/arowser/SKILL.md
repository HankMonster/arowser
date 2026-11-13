---
name: arowser
description: "Use when driving arowser pinned web windows in any scenario: showing URLs, dashboards, or local HTML; serving a local directory for data-driven pages (pagination, lazy loading, drill-down); per-window navigation/hide/close/zoom by id; global-hotkey window switching and in-page find; arowser-watch live-reload preview; multi-agent owner isolation; login-state profiles — or whenever arowser / arowser show / pinned web window / multi-window dashboard is mentioned."
---

# arowser: agent-programmable pinned web windows

Use the `arowser` CLI to show web pages in manageable windows; windows are addressed by unique id, so multiple windows and multiple agents never interfere. Full documentation lives in the repository [README.md](../../README.md); source and design history are in this directory.

## Prerequisites

```bash
command -v arowser || echo "missing"
```

If missing or a rebuild is needed: run `./build.sh` from the repository root (installs `~/Applications/arowser.app`, links `~/.local/bin/arowser` and `~/.local/bin/arowser-watch`). Quit the running instance first with `arowser quit --all`, or the old instance keeps holding the `arowser://` scheme.

## Common commands

```bash
id=$(arowser open <url> --title <name>)   # new window; unique id printed on stdout
arowser show "$id" [url]                  # with url: navigate; without: bring to front / unhide, no reload
arowser hide "$id"
arowser close "$id"
arowser reload "$id"
arowser list [--json]
url=$(arowser serve <dir> [--id name])    # mount a directory, print URL — see "Local directory serving"
arowser quit --all                        # global exit; --all is mandatory
```

- `open` without `--id` creates a new window every time; reuse a window with `show <id> <url>` or `open --id <id> ...`.
- `show <id>` without a url only brings the window to front / unhides it, without reloading; it accepts `--x/--y/--center/--w/--h` to move or resize only.
- Addresses without a scheme default to `https://`; local files accept absolute paths, `./`, `~`, or any existing path.
- **`file://` pages cannot fetch/XHR** (WebKit opaque origin); for on-demand data (pagination, lazy loading, drill-down) use the built-in serve — see "Local directory serving".
- `show <id> <url>` may also switch `--mobile/--no-mobile` and `--fit/--no-fit` (changing the UA reloads the page).
- `target=_blank` / `window.open` in pages navigates the current window by default (replaces the URL); only ⌘-click opens a new arowser window (inherits owner/profile/UA/fit, honors `windowFeatures`, and `window.close()` closes it).
- New windows default to 460×620, stacked from the top-right of the main screen, at **normal level, not floating** (changed 2026-11-13; previously always-on-top), and follow the current Space; `--float` pins on top / `--no-float` returns to normal level (`show` accepts both, switchable any time); the context menu Unfloat/Float on Top is equivalent. Reserve floating for explicit cases (the notify-user notification card must pass `--float`); otherwise agents judge per case. `--w/--h/--x/--y` set size and position.
- `--x/--y` is the window's top-left corner in the main-screen coordinate system (same coordinates as screenshots / System Events; secondary displays to the left/top may be negative); an omitted axis defaults to the top-right of the main screen's visible area (clearing the menu bar). `list --json` `x/y/w/h` use the same coordinate system.
- `--center` centers the window in the current main screen's visible area (clearing menu bar/Dock) and wins over `--x/--y`; works on `show` too.
- Display: `--fit` (default; scale down proportionally to window width, floor 0.3); `--no-fit` keeps 100%; `--mobile` uses an iPhone UA for mobile-first sites. The default UA is desktop Safari (sites treat the bare WKWebView UA as an embedded browser and serve blank pages).
- Zoom (window focused): `⌘+` (or `⌘=`) / `⌘-` in and out, `⌘0` back to 100%, `⌘9` re-enable fit-to-width; manual zoom overrides `--fit` until `⌘9` or an explicit `--fit`.
- Editing (window focused): `⌘C`/`⌘V`/`⌘X`/`⌘A`, `⌘Z`/`⇧⌘Z` via the system clipboard; works on inputs and selections.
- Reload (window focused): `⌘R` reload, `⇧⌘R` reload bypassing cache; CLI equivalent `arowser reload <id>`.
- Context menu (in page): Copy Link (link URL, or page URL on blank area) / Open in Default Browser / Back/Forward/Reload / Unfloat|Float on Top (per window, persisted in the `pinned` field) / Disable|Enable Drag Bar (hides the drag bar per window; top area becomes clickable, move with `⌥`+drag) / Hide Window (⌘H) / Close Window (⌘W, acts on the window under the cursor).
- Hide/switch: when focused, `⌘H` hides only the current window; the global `⌃⌥⌘L` (works from any foreground app, no Accessibility permission) opens a window picker (includes hidden windows, `●`/`○` markers) with three-way selection — hidden → show and activate, visible but unfocused (e.g. sunken after Unfloat) → bring to front, focused → hide; the context menu `Windows ▸` shares the list. Hotkeys are configurable via the `hotkey` field in `~/Library/Application Support/arowser/settings.json`.
- Window history: the global `⌃⌥⌘K` lists recently closed windows (default 24h, `historyHours` configurable); selecting reopens on the **original id** (geometry/profile/owner restored) — ids an agent saved in its session keep working after close. `arowser restore` manually restores the last ⌘Q session snapshot or crash leftovers.
- Session restore: a confirmed `⌘Q` snapshots all windows; the next launch restores them after 1.2s (hidden windows restore hidden); an agent cold-start `open`/`show` cancels the restore (one window in = one window out); CLI `quit --all` leaves no snapshot. Disable with `sessionRestore: false`.
- In-page find (window focused): `⌘F` opens a find bar top-right with live highlighting, `Return`/`Shift+Return` step matches, `Esc` closes; `⌘G`/`⇧⌘G` step without opening the input. Main frame only.
- Quote URLs containing `?`, `&`, or non-ASCII characters.

## Local HTML

```bash
arowser open /path/report/index.html     # absolute path
arowser open ./report.html               # relative path
arowser open /path/report                # directory: picks up index.html
```

- Also accepts `file://` URLs; spaces and non-ASCII paths are percent-encoded.
- A directory argument must contain `index.html`, or the CLI exits with an error.
- Relative CSS/JS/images work (loadFileURL grants read access to the HTML directory).
- In-page `fetch`/XHR against local files is blocked by WebKit (opaque origin, `Load failed`); use the built-in serve for data files, or inline the data.
- Dev preview: `arowser-watch <html-or-dir> [open options]` opens the page and auto-reloads on file changes; watches the whole directory by default, `--deep` recurses, `--file-only` watches a single file; Ctrl-C keeps the window, and the watcher exits when the window closes.

## Local directory serving (serve)

```bash
url=$(arowser serve /path/to/dir)                # → http://127.0.0.1:<port>/<id>/
arowser open "$url" --title demo
arowser open /path/to/dir --serve --title demo   # mount + open in one step
arowser serve /path/to/dir --id myapp            # explicit mount name (default: dirname-hash4)
```

- Lifecycle follows the app: after the last window closes the app keeps running (keepAlive) and the listener stays up; a clean exit (⌘Q / `quit --all`) stops it, and any later `serve` restarts it.
- URLs survive restarts: port and mounts persist in `~/Library/Application Support/arowser/serve.json`; the same directory gets the same URL after restart. Port conflicts rebind to a temporary port and rewrite the file (old absolute URLs die — **reference in-page resources by relative URL** and nothing breaks).
- Repeated `serve` of the same directory is idempotent (same URL); multiple directories can be mounted at once.
- Security: binds 127.0.0.1 only; only explicitly served directories are reachable; Host header allowlist (DNS rebinding); `..` and symlink escapes blocked; a directory without `index.html` returns 404 (no listing); `Cache-Control: no-store` (refresh sees edits immediately).
- **No auth on localhost** (any local process can read — never serve sensitive directories); no unmount command yet — mounts accumulate in serve.json; delete the file to reset.

## Multi-window and multi-agent

- Each scenario or session uses its own window id; never guess or reuse another agent's id.
- Every id-addressed command (`show`/`hide`/`close`/`reload`) accepts `--owner`/`--force`.
- Owner resolution: `--owner` → `$AROWSER_OWNER` → `$CLAUDE_CODE_SESSION_ID` (prefixed `cc-`) → `anonymous`. Cross-owner operations exit 3; `--force` is for manual cleanup only.
- Agents without session env vars (Codex etc.): `AROWSER_OWNER=<stable-id> arowser ...`.

## Login states

- Default jar: all default windows share one persistent store; logins survive restarts.
- `--profile NAME`: same-name profiles share one persistent jar; the name derives a UUID via SHA256, so renaming means a fresh empty jar.
- `--private`: ephemeral jar, wiped when the window closes.
- A jar binds at window creation; `show` with a different profile is rejected (exit 3) — switch jars only by opening a new window.
- **Logins survive cold restarts**: an internal cookie mirror keeps all jars (default included) alive — WebKit never persists session cookies without an expiry; arowser mirrors them on window close/exit and reinjects on jar creation, so session-cookie logins survive in the default jar too. A force-kill loses the last stretch of changes.
- On disk: `~/Library/WebKit/com.hank.arowser/` (default `WebsiteData`, profiles under `WebsiteDataStore/<uuid>`); quit the app and delete the directory to reset a login. No clear command yet.
- No cookie sharing with Safari/Chrome; no Keychain/autofill integration.

## Errors and status

- Exit codes: `0` success (stdout prints the window id); `3` rejected (no such window, owner mismatch, profile conflict); `4` no ack (app not running or not registered).
- The process stays resident by default (since 2026-11-12): closing the last window keeps the app alive; global hotkeys keep working, and with zero windows `⌃⌥⌘K` reopens from history; exit via ⌘Q (confirm dialog when windows exist) or `quit --all`. Old behavior: `{"keepAlive": false}`.
- State file: `~/Library/Application Support/arowser/state.json`; `list --json` includes id/owner/profile/url/pageTitle/visible/frame/x/y/w/h/zoom. With the app not running, `list` notes it on stderr and shows last-known state.
- Windows are borderless: drag the 28pt top bar or ⌥+drag anywhere to move, edges resize; the top 28pt strip does not receive page clicks (if it blocks page content, Disable Drag Bar in the context menu hides it temporarily). `⌘W`/`close <id>` closes the focused window only; `⌘Q` quits the whole app (confirm dialog with windows; Return defaults to Cancel), CLI `quit --all` exits directly without a dialog.

## Boundaries

- The app is a regular app (since 2026-11-13, previously LSUIElement): Dock icon, ⌘Tab, and a menu bar status item (Windows ▸ / History ▸ / Quit; `{"statusItem": false}` disables). Dock click / `open -a` / Raycast launch of a running instance is a reopen event: zero windows → history picker, all hidden → window picker, visible windows → plain activate without menus. The CLI and hotkeys remain the primary control plane.
- The rendering engine is system WebKit (not Chromium); Chrome-only sites may misrender — re-evaluate with an Electron build if that bites.
- The control plane is the `arowser://` URL scheme plus ack files; no Accessibility permission and no listening port.

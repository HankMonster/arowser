---
name: notify-user
description: "Notify the user at the computer with an arowser pinned card: task/feature completed, needs human help (testing, review, authorization), or a long-running job finished. Use when a task completes and the user should know, when you need the user's hands or confirmation, or when choosing between an on-deck (arowser window) and away (the user's own notification channel) notification."
---

# notify-user: pinned-window notifications

When the user is at the computer, the most effective notification is an arowser pinned card: it never steals focus, stays on top, and reads better than terminal output.

## Channel choice

- User on deck (this machine's session) → this skill, an arowser window
- Result worth studying (tables/charts/long output) → the show-info presentation window, not a notification
- User away / unresponsive for a long time → the user's own away-notification channel; do not double-send

## Shared semantics

The notification window is **one shared window across agents**, not one per session:

- Fixed `--id notify-user --owner notify`: every session uses the same shared owner, so cards overwrite each other instead of being rejected; operations without this owner are refused by arowser (protects the card, exit code 3)
- A later card replaces an earlier one — notifications are transient; details live in each session's own record
- After the user closes it with ⌘W, the next notification recreates the window

## Usage

```bash
command -v arowser >/dev/null || { echo "arowser missing — install/build it first (see the arowser skill)"; exit 1; }
SKILL_DIR="<skill-dir>"   # where you installed skills/notify-user (absolute path)
card="/tmp/arowser-notify/card-$(date +%H%M%S).html"
mkdir -p /tmp/arowser-notify
meta="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)") · ${AROWSER_OWNER:-cc-${CLAUDE_CODE_SESSION_ID:0:8}} · $(date '+%m-%d %H:%M')"
python3 - "$card" "$meta" "$SKILL_DIR/assets/card.html" <<'PY'
import sys
tpl = open(sys.argv[3]).read()
open(sys.argv[1], "w").write(
    tpl.replace("{{TITLE}}", "✅ Title: one-line conclusion")
       .replace("{{ITEMS}}", "<li><span class=done>✔</span> Done item A</li>\n<li><span class=done>✔</span> Done item B")
       .replace("{{ASK}}", "When help is needed, name the concrete action: which key to try, what to click; write 'none' if nothing is needed")
       .replace("{{META}}", sys.argv[2]))
PY
arowser open "$card" --id notify-user --owner notify --title Notify --float --w 380 --h 320
```

(The template path is passed explicitly — `python3 -` runs with `__file__ = "<stdin>"`, so a `__file__`-relative lookup would resolve against the caller's CWD. Adapt the fill snippet to your agent runtime; the contract is the four placeholders and the fixed `open` flags.)

## Card rules

- Title is a one-line conclusion, prefixed by type: `✅` done / `🤝` needs you / `⚠️` problem
- **Always keep the `{{META}}` provenance line** (project · session · time, auto-filled by the command above): in a shared window it is the only clue to who is calling
- Put items needing the user in the highlighted block (`{{ASK}}`), with the concrete action — not "please review"
- Fixed footer: "close with ⌘W when read"; the template ships with font fallbacks
- More content → taller window (`--h 400+`); structure may adapt, keep the dark card + three sections; template at [assets/card.html](assets/card.html)
- `--float` is mandatory (since 2026-11-13 arowser windows default to normal level, not on top) — the notification card must float to do its job; notify is the canonical floating case, don't drop the flag

## Boundaries

- A notification is a closing action: finish commits/verification first, then post the card; the card must agree with what the conversation says
- Ask consent in the card or conversation before synthetic-event/popup testing — don't test by interrupting
- A card does not replace answering in the conversation: when the user is waiting in the terminal, answer there; cards are for when they are not looking at the terminal

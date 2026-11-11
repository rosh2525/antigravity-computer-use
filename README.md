# Computer Use for Antigravity

[![build](https://github.com/rosh2525/antigravity-computer-use/actions/workflows/build.yml/badge.svg)](https://github.com/rosh2525/antigravity-computer-use/actions/workflows/build.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Codex-style computer use for macOS, as a plugin for Google's [Antigravity](https://antigravity.google).
The agent works app by app: it reads an app's accessibility tree (every element numbered) plus a
screenshot of its window, then clicks, types, scrolls and pastes by element, in the background,
without taking over your mouse or keyboard.

> Independent community project. Not affiliated with or endorsed by Google or OpenAI; it reimplements
> the *design* of Codex's computer-use tools with its own native helper.

**Requirements:** macOS 14+ (tested on macOS 26, Apple silicon), Antigravity 2.x, and the Xcode Command
Line Tools (`xcode-select --install`) to build from source.

## What matches Codex

- Same tools and parameters: `get_app_state`, `click`, `set_value`, `type_text`, `paste`,
  `press_key`, `scroll`, `drag`, `select_text`, `perform_secondary_action`, `list_apps`.
- Accessibility-tree-first state with a screenshot. After the first call per app the tree comes back
  as a diff, with element indexes that stay stable across calls.
- Apps launch in the background without taking focus; input goes to the target app only.
- Automatic settle wait after actions (about 1 s, up to ~5 s while the app shows a spinner).
- `paste` restores your clipboard afterwards; Markdown and HTML are pasted as rich text.
- An "Antigravity is using your computer · Esc to cancel" pill and a ripple at each click. Esc stops
  the agent for the rest of the turn.
- Refuses to act while the screen is locked.
- You approve each app the first time it is used (Allow / Always Allow / Don't Allow).
- The skill carries the same kind of confirmation policy for risky actions.

## Install

```bash
git clone https://github.com/rosh2525/antigravity-computer-use ~/.gemini/config/plugins/computer-use
~/.gemini/config/plugins/computer-use/scripts/install.sh
```

No Xcode tools? Download `computer-use-plugin-macos-arm64.zip` from the
[latest release](https://github.com/rosh2525/antigravity-computer-use/releases/latest), unzip it so the
folder is `~/.gemini/config/plugins/computer-use`, and run `scripts/install.sh` (it uses the prebuilt
app and clears the download quarantine flag).

Then:
1. Allow **AgyComputerUse** in System Settings → Privacy & Security → **Accessibility** and
   **Screen & System Audio Recording** (the setup window that opens has a button for each). If it isn't
   listed, click **+** and pick `~/.gemini/config/plugins/computer-use/AgyComputerUse.app`
   (⌘⇧G lets you paste the path).
2. Restart Antigravity, then ask it something like *"Open Calculator and work out 1,284 × 37"*.

**Keep permissions across rebuilds (optional, for people building from source).** With ad-hoc signing,
macOS ties the permissions to one exact build, so every rebuild needs them granted again. Create a
self-signed certificate once: Keychain Access → Certificate Assistant → Create a Certificate…, name
**AgyComputerUse Local**, Identity Type *Self-Signed Root*, Certificate Type *Code Signing*.
`scripts/build.sh` picks it up automatically (or set `AGY_CU_SIGN_IDENTITY`).

## Uninstall

```bash
~/.gemini/config/plugins/computer-use/bin/agy-cu stop
rm -rf ~/.gemini/config/plugins/computer-use ~/.gemini/antigravity/plugin_data/computer-use
```
Then remove **AgyComputerUse** from the two Privacy & Security lists.

## Issues and feedback

Found a bug or an app it can't drive? [Open an issue](https://github.com/rosh2525/antigravity-computer-use/issues/new/choose)
— the template asks for `bin/agy-cu status` and the service log. Security problems: please use
[private reporting](https://github.com/rosh2525/antigravity-computer-use/security/advisories/new).
Contributions welcome, see [CONTRIBUTING.md](CONTRIBUTING.md).

## How it fits together

```
Antigravity ──stdio MCP──▶ agy-cu mcp ──unix socket──▶ AgyComputerUse.app (service)
                                                      ├─ AXUIElement tree, actions
                                                      ├─ CGEvent.postToPid input
                                                      ├─ ScreenCaptureKit window shots
                                                      └─ overlay, Esc monitor, app approvals
Stop hook ─▶ bin/agy-cu notify turn-ended  (hides the overlay, resets per-turn state)
```

The service is its own app bundle (`dev.agy.computer-use`) so macOS attributes the permissions to it
rather than to Antigravity. It starts on demand and keeps running in the background.

| Path | Purpose |
|---|---|
| `src/` | Swift package for `agy-cu` (service, MCP server, CLI) |
| `skills/computer-use/SKILL.md` | Agent runbook and confirmation policy |
| `rules/AGENTS.md` | Always-on rule while the plugin is enabled |
| `hooks.json` | Stop hook that ends the turn for the service |
| `~/.gemini/antigravity/plugin_data/computer-use/` | socket, `approvals.json`, `settings.json`, `service.log` |

## Commands

```bash
~/.gemini/config/plugins/computer-use/bin/agy-cu status           # service + permission status
~/.gemini/config/plugins/computer-use/bin/agy-cu permissions      # reopen the setup window
~/.gemini/config/plugins/computer-use/bin/agy-cu reset-approvals  # forget "Always Allow" apps
~/.gemini/config/plugins/computer-use/bin/agy-cu stop             # quit the service
~/.gemini/config/plugins/computer-use/bin/agy-cu call get_app_state '{"app":"Calculator"}'
```

Set `"askBeforeUsingNewApps": false` in `settings.json` to skip per-app approval prompts.

## Limits

- ⌘-shortcuts in `press_key` (and the paste in `paste`) go through the app's own menu item when it
  has one, which works in the background. Some apps (TextEdit, for one) ignore a background Paste:
  plain text is then inserted through accessibility; Markdown/HTML briefly bring the app forward,
  paste, and hand focus back to whatever you were using.

- Clicks and drags by coordinate first hit-test the accessibility element at that pixel: buttons are
  pressed, and in text fields the caret / word / line / drag selection is set at the exact character,
  all in the background. Only when nothing accessible is there (canvases, games) are raw mouse events
  posted, and many apps ignore those while they are not frontmost.
- Screenshots need the window on screen in the current Space (not minimized or hidden).
- Chromium and Electron apps get their accessibility tree switched on the first time they are used.

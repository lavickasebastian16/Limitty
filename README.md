# Limitty

See your **Claude**, **Codex** and **Antigravity (`agy`)** usage limits at a glance, with a bar and reset countdown for each limit window.

## 📱 iPhone app + widgets (Claude + Codex + Gemini)

A native SwiftUI app with Home Screen and Lock Screen widgets. You build and install it with [xtool](https://github.com/xtool-org/xtool) from Linux or Windows (WSL); you don't need a Mac.
Guide: **[ios/README.md](ios/README.md)**.

Rather not set up xtool? [`scriptable/`](scriptable/README.md) has a lighter widget-only version for the free Scriptable app.

## 🤖 Agent status on your iPhone (Claude Code, Codex, agy)

See whether each agent on your PC is **working**, **needs you** (a permission prompt or question), or **idle**, and get a push alert when one needs you or finishes. A small companion on your PC watches the agents and relays their status to the iPhone app, end-to-end encrypted, through [ntfy](https://ntfy.sh).

```bash
npm install
npm run agent:setup   # installs the hooks, starts the relay at login, shows a QR code
```

Scan the QR code with your iPhone's Camera app to pair. Then, in Limitty, tap **Get alerts on this iPhone** to set up the free ntfy app for push alerts. More details are below under [How agent status works](#how-agent-status-works).

## 🖥️ Desktop widget (Claude + Codex + agy)

A small always-on-top window for Windows, macOS and Linux. It reads the logins your CLIs already store on the computer. Antigravity only works here, because its quota lives on the computer that runs it.

```
● Claude  [Max]
  Session (5h)   ███████░░░░░░  42%   resets in 2h 18m
  Weekly         █████████░░░░  67%   resets in 3d 4h
● Codex   [Plus]
  5h window      ████████████░  91%   resets in 24m
● Antigravity
  Gemini Pro     ██░░░░░░░░░░░  15%   resets in 3h 2m
```

Bars turn amber at 60% and red at 85%.

### Desktop setup

You need [Node.js](https://nodejs.org) 18 or newer.

```bash
git clone https://github.com/lavickasebastian16/Limitty.git
cd Limitty
npm install
npm start          # opens the widget (top-right corner)
```

Want it in the terminal instead? `npm run check` (or `npm run check -- --json`).

### Using the desktop widget

- **Drag** the header to move it. It remembers where you put it.
- **↻** refreshes now. It also refreshes on its own every 5 minutes by default.
- **⋯** opens settings: refresh interval, always-on-top, which providers to show, start at login, reset position.
- **✕** hides it to the tray/menu-bar icon. Click the tray icon to bring it back. Quit from the tray menu.

### Where the desktop numbers come from

Limitty reads the logins your CLIs already store. It needs no API keys and never writes or refreshes those logins.

| Provider | Login it reads | Where the limits come from |
|---|---|---|
| **Claude** | `~/.claude/.credentials.json` (on macOS, the Keychain item `Claude Code-credentials`), or `CLAUDE_CODE_OAUTH_TOKEN` | `api.anthropic.com/api/oauth/usage`, the same data as Claude Code's `/usage` (5-hour session, weekly, and per-model weekly limits) |
| **Codex** | `~/.codex/auth.json` (or `$CODEX_HOME`) | `chatgpt.com/backend-api/wham/usage`, the same data as Codex's `/status`. If that fails, it uses the latest `rate_limits` snapshot in `~/.codex/sessions/**.jsonl` |
| **Antigravity** | Antigravity's own running language server | Limitty finds the local Antigravity / `agy` language server process, reads its CSRF token from the process arguments, and asks it for the quota summary on `127.0.0.1`. If no server is running, it falls back to `agy -p /usage --output-format json` (set `ANTIGRAVITY_CLI_PATH` if `agy` isn't on your PATH) |

> These usage endpoints are the ones the official tools use internally. They aren't public, documented APIs, so a vendor update could change them. Each provider lives in its own small file under `src/providers/` and is easy to adjust.

### Desktop troubleshooting

- **"Not signed in"**: log in once with the CLI (`claude`, `codex login`, or open Antigravity / run `agy`).
- **"Login expired"**: run that CLI once so it refreshes its token, then hit ↻.
- **Antigravity "not running"**: open the Antigravity app or run `agy` in a terminal and leave it running.

## Development

```bash
npm test                 # desktop + Scriptable tests
(cd ios && swift test)   # iPhone app core tests (works on Linux)
npm run check            # print live limits in the terminal
node scripts/make-icon.js  # regenerate assets/tray.png
```

Project layout:

```
src/main.js              Electron main process: widget window, tray, refresh timer
src/preload.js           Safe bridge between the window and the main process
src/renderer/            Widget UI (HTML/CSS/JS)
src/providers/           One module per service: claude.js, codex.js, antigravity.js
src/cli.js               Terminal output
ios/                     iPhone app + widget (SwiftUI, built with xtool)
scriptable/              iPhone widget as a Scriptable script
```

## How agent status works

| Agent | How Limitty knows | Needs you | Finished |
|---|---|---|---|
| **Claude Code** | hooks in `~/.claude/settings.json` | ✅ permission prompts and questions (Notification hook) | ✅ Stop hook |
| **Codex** | its session logs (`~/.codex/sessions`), plus `notify` in `~/.codex/config.toml` | ⚠️ guessed: Codex doesn't log approval prompts, so a command that's been pending for 30 s shows as "maybe waiting" | ✅ |
| **Antigravity (agy)** | hooks in `~/.gemini/config/hooks.json` | ⚠️ guessed, the same way as Codex | ✅ Stop hook |

- **Commands:**
  - `npm run agent` runs the relay (setup already makes it start at login on Windows, macOS and Linux with systemd).
  - `npm run agent:status` shows what it sees.
  - `node src/agents/cli.js test` sends a test alert.
  - `node src/agents/cli.js pair` shows the QR code again.
  - `node src/agents/cli.js uninstall` removes the hooks and the start-at-login entry.
- **Restart open agent sessions** after setup so they load the hooks.
- **WSL:** run the agent **inside WSL** if your agents run there.
- **Privacy:**
  - Status is encrypted (AES-256-GCM) with a key that's only on your PC and phone. ntfy only sees ciphertext.
  - Push alerts are plain text so the ntfy app can show them: agent name, project folder, and the prompt message. Set `"showProjectNames": false` in `~/.limitty/agent.json` to send only the agent name.
- **Limits:**
  - ntfy.sh's free tier allows 250 messages a day per IP address. Limitty sends status only when something changes (at most every 30 s), plus a heartbeat every 30 minutes, and slows down if it gets close to the limit.
  - For more, set `server` and `token` in `~/.limitty/agent.json` to your own ntfy server or a paid account, then pair again.
- **Desktop widget:** while it's open, the desktop widget runs the relay too, so only one copy runs.

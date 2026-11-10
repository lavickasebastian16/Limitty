# Limitty

**Version 1.01.000**

See your **Claude**, **Codex** and **Antigravity (`agy`)** usage limits at a glance, with a bar and reset countdown for each limit window. Have an AI CEO hand your tasks to those agents. Follow everything from your iPhone or your PC.

## ⬇️ Download

Every build is on the **[latest release](https://github.com/lavickasebastian16/Limitty/releases/tag/latest)**:

| You have | File | Install |
|---|---|---|
| iPhone | `Limitty-1.01.000.ipa` | Sideloadly, AltStore or SideStore; see [ios/README.md](ios/README.md) |
| Omarchy / Arch Linux | `Limitty-1.01.000-x64.pacman` | `./linux/omarchy-install.sh` (recommended), or `sudo pacman -U Limitty-*.pacman` |
| Any Linux | `Limitty-1.01.000-x86_64.AppImage` | `chmod +x Limitty-*.AppImage && ./Limitty-*.AppImage` |

## 🧩 Choose your agents (installed for you)

The first time you open the desktop app, it asks which agents you want: **Claude Code**, **Codex** and/or **Antigravity**. Tick them and press **Install**. Limitty then:
1. Installs any that are missing, with each company's official installer. They go in `~/.local/bin`, with no admin password needed.
   - **Claude Code:** `curl -fsSL https://claude.ai/install.sh | bash`
   - **Codex:** the official release from [github.com/openai/codex](https://github.com/openai/codex/releases)
   - **Antigravity:** `curl -fsSL https://antigravity.google/cli/install.sh | bash`
2. Opens a terminal window to sign in, the same way as running the tool yourself.
3. Uses only the ticked agents: the widget shows their limits, and the Company gives them work.

Change your choice any time: menu (⋯) → **Choose agents…**, the **Choose agents…** button in the Company window, or `limitty --agents`.

From a terminal: `node src/agents/cli.js agents` shows what's installed. Then:
- `agents use claude codex` sets your choice.
- `agents install` installs the missing ones.
- `agents login codex` signs in.

Automatic install works on Linux and macOS. On Windows, install the agents from their websites.

## 📱 iPhone app + widgets (Claude + Codex + Gemini)

A native SwiftUI app with Home Screen and Lock Screen widgets. You build and install it with [xtool](https://github.com/xtool-org/xtool) from Linux or Windows (WSL); you don't need a Mac.
Guide: **[ios/README.md](ios/README.md)**.

Rather not set up xtool? [`scriptable/`](scriptable/README.md) has a lighter widget-only version for the free Scriptable app.

## 🤖 Agent status on your iPhone (Claude Code, Codex, agy)

See whether each agent on your PC is **working**, **needs you** (a permission prompt or question), or **idle**, and get a push alert when one needs you or finishes. You link the PC and phone by **signing in with the same GitHub account** on both.

1. **PC:** in the Limitty desktop app, open the menu (⋯) → **Connect agents to iPhone…**, then enter the code shown on GitHub's page. This installs the agent hooks and makes Limitty start at login. Headless or WSL? Run `npm install && npm run agent:setup` instead.
2. **iPhone:** Limitty → **Agents on your PC** → **Sign in with GitHub**, and enter the code shown there.
3. *Optional:* tap **Get alerts on this iPhone** to set up push alerts with the free ntfy app.

Status is stored in a **private Gist** on your GitHub account. Limitty only asks for Gist access. More details are below under [How agent status works](#how-agent-status-works).


## 🏢 Company: give tasks to your agents

Run your agents like a small company:
- **You** give a task, from the iPhone (**Tasks → New task**), the desktop app (the briefcase button → **Company** window), or a terminal (`node src/agents/cli.js task "…" --in <folder>`).
- **The CEO** (Claude Code by default) reads the task. It splits the task into up to 4 steps if useful, and gives each step to the best worker **and model**. The CEO is on the team too, and takes steps itself when it's the best fit (marked **CEO**).
- **Model choice** matches the work to the model, using live usage limits for each model:
  - **Claude Code:** Opus for hard design or tricky bugs, Sonnet for normal coding, Haiku for small edits and docs.
  - **Codex:** high, medium or low reasoning effort.
  - **Antigravity:** Gemini Pro or Flash.
  - It uses Claude's separate weekly Opus and Sonnet limits and the Gemini Pro and Flash quotas, and avoids any model under 15% left unless nothing else fits.
- **The workers** (Claude Code, Codex, Antigravity) carry out the steps in order, in your project folder. Each step sees the results of the earlier ones.
- You follow progress, the CEO's plan, and each worker's output on the phone or PC. You get a push alert when a task is done or fails, and you can cancel or rerun any task.

Details:
- **Workers edit your project directly.** They can change files and run commands there:
  - Claude runs with `--permission-mode acceptEdits` and shell commands allowed.
  - Codex runs with `--full-auto` (its workspace sandbox).
  - agy runs with `-p`.
  - Use git so you can review or undo their changes.
- **Projects:** add folders with **Add folder…** in the Company window. Folders your agents worked in recently show up too.
- **Which process runs it:** the desktop app or the background agent (`npm run agent`), whichever starts first; the other just shows the tasks. Tasks from the phone go through the same private GitHub Gist as agent status, so they need GitHub sign-in.
- **CEO choice:** set `"ceo": "codex"`, `"agy"` or `"rules"` in `~/.limitty/agent.json`. `"rules"` uses no AI: it picks the free worker with the most limit left, and a balanced model with room left. Planning itself uses the CEO's balanced model (for example Sonnet) to save its limit.
- **Settings** in `~/.limitty/agent.json` → `"workers"`:
  - `"allowCommands": false` stops Claude workers from running shell commands.
  - `"agyModels": { "pro": "…", "flash": "…" }` turns on Gemini Pro or Flash choice for agy. Use the slugs `agy models` shows. agy's `--model` flag differs between versions, so it's off until you set this.
- **Limits:** a task that's running when Limitty or the PC stops is marked as interrupted; use **Run again**. Each step stops after 45 minutes.

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

## 🐧 Linux / Omarchy

Limitty runs on Omarchy (Arch + Hyprland + Waybar):

```bash
git clone https://github.com/lavickasebastian16/Limitty.git && cd Limitty
./linux/omarchy-install.sh            # downloads the latest build (needs `gh auth login`, since the repo is private)
./linux/omarchy-install.sh --source   # or builds it on your machine
```

The script:
1. Installs the package (`/usr/bin/limitty`).
2. Adds **Hyprland window rules** (`~/.config/hypr/limitty.conf`, or `limitty.lua` if you use `hyprland.lua`). The widget floats top-right, is pinned on every workspace, has no border or shadow, and doesn't steal focus. It also starts Limitty with Hyprland.
3. Copies a **Waybar module** to `~/.config/waybar/`. It shows your limits (`C 42% · X 91% · G 15%`), agents that need you (`! 1`), working agents (`● 2`) and running tasks (`▸ 1`), with full details in the tooltip. Left-click toggles the widget; right-click opens Company. You add it to your bar yourself, so your layout stays yours (the script prints how), then run `omarchy restart waybar`.

Handy for keybinds: `limitty --toggle`, `limitty --company`, `limitty --agents`, `limitty --waybar` (prints the Waybar JSON). **Start at login** in the menu writes `~/.config/autostart/limitty.desktop`. On Hyprland 0.52 or older, use the `windowrulev2` lines at the bottom of `linux/hypr/limitty.conf`.

## 🔢 Versions

Limitty uses **X.XX.XXX**:
- **X** is the main version.
- **XX** is a big upgrade.
- **XXX** is a minor update.

For example: `1.00.000` → `1.00.001` (fix) → `1.01.000` (new feature) → `2.00.000`.

Set it everywhere (desktop, Linux packages, iPhone app and widget) with:

```bash
node scripts/set-version.js 1.01.000
```

npm and Electron need plain semver, so `1.01.000` is stored there as `1.1.0`. The iPhone build number is `X*100000 + XX*1000 + XXX`. You see `1.01.000` everywhere: the desktop menu, the Company window, the iPhone app, `limitty-agent --version` and the release title.

## Development

```bash
npm test                 # desktop + Scriptable tests
(cd ios && swift test)   # iPhone app core tests (works on Linux)
npm run check            # print live limits in the terminal
node scripts/make-icon.js  # regenerate the icons
npm run dist:linux         # build the AppImage, pacman and tar.gz into dist/
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

## Register the GitHub sign-in (one time)

1. Open <https://github.com/settings/applications/new>.
2. Fill in:
   - **Application name:** `Limitty`
   - **Homepage URL** and **Authorization callback URL:** `https://github.com/lavickasebastian16/Limitty` (the callback URL isn't used)
3. Click **Register application**. On the next page, tick **Enable Device Flow**, then click **Update application**.
4. Copy the **Client ID** (it starts with `Ov23` or `Iv1.`). It isn't secret, and you don't need a client secret. Run `node scripts/set-github-client-id.js <Client ID>` and commit the two files it changes. GitHub then rebuilds the iPhone app with sign-in enabled.

## How agent status works

| Agent | How Limitty knows | Needs you | Finished |
|---|---|---|---|
| **Claude Code** | hooks in `~/.claude/settings.json` | ✅ permission prompts and questions (Notification hook) | ✅ Stop hook |
| **Codex** | its session logs (`~/.codex/sessions`), plus `notify` in `~/.codex/config.toml` | ⚠️ guessed: Codex doesn't log approval prompts, so a command that's been pending for 30 s shows as "maybe waiting" | ✅ |
| **Antigravity (agy)** | hooks in `~/.gemini/config/hooks.json` | ⚠️ guessed, the same way as Codex | ✅ Stop hook |

- **Commands:**
  - `npm run agent:setup` signs in with GitHub and installs the hooks; add `-- --qr` to pair with a QR code and the ntfy relay instead, with no GitHub account.
  - `npm run agent` runs the relay (setup already makes it start at login on Windows, macOS and Linux with systemd).
  - `npm run agent:status` shows what it sees.
  - `node src/agents/cli.js test` sends a test alert.
  - `node src/agents/cli.js pair` shows the QR code again.
  - `node src/agents/cli.js logout` signs the PC out of GitHub.
  - `node src/agents/cli.js uninstall` removes the hooks and the start-at-login entry.
- **Restart open agent sessions** after setup so they load the hooks.
- **WSL:** run the agent **inside WSL** if your agents run there.
- **Privacy:**
  - With GitHub sign-in, status (agent name, project folder, state) lives in a private ("secret") Gist on your account. Only you can list it; delete the Gist to remove it.
  - With QR pairing, status is encrypted (AES-256-GCM) with a key that's only on your PC and phone. ntfy only sees ciphertext.
  - Push alerts are plain text so the ntfy app can show them: agent name, project folder, and the prompt message. Set `"showProjectNames": false` in `~/.limitty/agent.json` to send only the agent name.
- **Limits:**
  - GitHub mode updates the Gist at most every 15 s, plus every 10 minutes as a heartbeat, well within GitHub's API limits.
  - ntfy.sh's free tier allows 250 messages a day per IP address (it's used for push alerts, and for status in QR mode). Limitty sends status only when something changes (at most every 30 s), plus a heartbeat every 30 minutes, and slows down if it gets close to the limit.
  - For more, set `server` and `token` in `~/.limitty/agent.json` to your own ntfy server or a paid account, then pair again.
- **Desktop widget:** while it's open, the desktop widget runs the relay too, so only one copy runs.

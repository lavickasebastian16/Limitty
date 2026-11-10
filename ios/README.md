# Limitty for iPhone

A home-screen and lock-screen widget showing your **Claude** and **Codex** usage limits, with a bar and reset countdown for each limit window.

Limitty runs inside **[Scriptable](https://apps.apple.com/app/scriptable/id1405459188)**, a free App Store app that runs JavaScript and can make real iPhone widgets. You don't need a Mac or Xcode, and nothing gets sideloaded.

> **Antigravity (agy) isn't in the iPhone version.** Its quota only exists on the computer where Antigravity runs, so a phone can't ask for it directly. Use the desktop widget (`npm start` in the repo root) for agy.

## 1. Install the script

1. Install **Scriptable** from the App Store.
2. On your iPhone, open [`ios/Limitty.js`](Limitty.js) on GitHub, tap **Raw**, then select all and copy.
3. In Scriptable, tap **+**, paste, tap the title at the top, and name it **Limitty**. Tap **Done**.

## 2. Add your logins (one time)

Run **Limitty** in Scriptable (tap it). A menu appears with **Claude login** and **Codex login**. Paste each value below. They're saved in the iOS Keychain on your phone and are only ever sent to claude.ai and chatgpt.com.

The easiest way to copy these values is from a browser on a **computer** where you're signed in. Send them to yourself (Notes, email, a message), then copy them on the phone. With the value on your clipboard, the menu offers **Use clipboard**.

### Claude: the `sessionKey` cookie (lasts about a month)

1. On a computer, open **claude.ai** in Chrome or Edge and sign in.
2. Press **F12** (Mac: ⌥⌘I). Go to **Application**, then **Cookies**, then `https://claude.ai`.
3. Copy the **Value** of `sessionKey`. It starts with `sk-ant-sid…`.

Why not the Claude Code token? The long-lived `claude setup-token` token is blocked from reading usage. It lacks the `user:profile` permission. The normal Claude Code login token expires within hours.

### Codex: pick one

**A. ChatGPT web cookie (recommended, lasts weeks).** The phone uses it to get a fresh token by itself each time.
1. On a computer, open **chatgpt.com** and sign in.
2. Press **F12**. Go to **Application**, then **Cookies**, then `https://chatgpt.com`.
3. Copy the value of `__Secure-next-auth.session-token`.
   If you only see `…session-token.0` and `…session-token.1`, copy both in this form:
   `__Secure-next-auth.session-token.0=VALUE0; __Secure-next-auth.session-token.1=VALUE1`

**B. Codex access token (expires after about 10 days).** Open `~/.codex/auth.json` on your computer and copy `tokens.access_token` (starts with `eyJ…`). Paste a new one when the widget says *Token expired*.

## 3. Add the widget

1. Long-press the home screen, tap **Edit**, then **Add Widget**, then **Scriptable**. Pick a size (medium fits both services best) and tap **Add Widget**.
2. Long-press the new widget, tap **Edit Widget**, and set **Script** to **Limitty**.
3. Optional: set **Parameter** to `claude` or `codex` to show only one service.

Lock-screen widgets (rectangular and inline) work the same way.

## How it behaves

- iOS decides when widgets refresh, usually every 15–30 minutes. Tap the widget to open Scriptable and refresh right away.
- Bars turn amber at 60% and red at 85%.
- If the network drops, the widget keeps showing the last numbers for up to a day, marked ⏱.
- **Login expired** means the cookie or token ran out. Run Limitty in Scriptable and paste a new one.

## Caveats

- These are the same usage endpoints the claude.ai and ChatGPT websites use. They aren't public APIs, so Anthropic or OpenAI could change them.
- claude.ai and chatgpt.com sit behind Cloudflare, which sometimes blocks non-browser requests. If Codex shows *Blocked by chatgpt.com*, use option B (access token).
- Your cookie is a full login to that account. Keep it private, and sign out of the website to cancel it.

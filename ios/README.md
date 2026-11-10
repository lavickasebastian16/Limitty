# Limitty for iPhone (native app + widgets)

A native SwiftUI app with Home Screen and Lock Screen widgets showing your **Claude** and **Codex** usage limits: a bar per limit window, the percentage used, and when it resets.

Download the ready-made `.ipa`, or build it yourself with **[xtool](https://github.com/xtool-org/xtool)** from **Linux or Windows (WSL)**. You don't need a Mac or a paid developer account either way.

> **Antigravity (agy) isn't included.** Its quota only exists on the computer where Antigravity runs, so the phone can't ask for it. Use the desktop widget (`npm start` in the repo root) for agy.

## Easiest: install the ready-made .ipa

GitHub builds `Limitty.ipa` automatically on every change to `ios/`. Download it from the **[ipa-latest release](https://github.com/lavickasebastian16/Limitty/releases/tag/ipa-latest)**. It's also attached to each run of the **Build iPhone .ipa** workflow under the repo's **Actions** tab.

The .ipa is **unsigned**: iOS only installs apps signed for your device. A sideloading tool signs it with your (free) Apple ID and installs it:

- **[Sideloadly](https://sideloadly.io)** (Windows or Mac): plug in your iPhone, drag in `Limitty.ipa`, enter your Apple ID, and click Start.
- **[AltStore](https://altstore.io)** or **[SideStore](https://sidestore.io)**: open the .ipa from the AltStore or SideStore app.

Then on the iPhone:
1. Turn on **Settings → Privacy & Security → Developer Mode**.
2. Go to **Settings → General → VPN & Device Management** and trust your Apple ID.

With a free Apple ID, the app stops opening after 7 days. Sideloadly and AltStore can renew it.

> If the app shows "The widget can't read your logins", the sideloading tool dropped the shared App Group. The app still works, but the widget can't. Try a different tool, or build with xtool (below).

## Build it yourself with xtool

### What you need

- A **Linux** PC, or **Windows with WSL**
- A USB cable for your iPhone
- An **Apple ID**. A free one works. xtool's docs suggest a spare Apple ID, because free-account sign-in uses private Apple APIs.

### 1. Install xtool (one time)

Follow xtool's [Linux/Windows install guide](https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Installation-Linux.md). In short:

1. **Windows only:** install WSL, then [USBIPD](https://learn.microsoft.com/en-us/windows/wsl/connect-usb) so WSL can see your iPhone over USB.
2. Install the **Swift toolchain** from <https://swift.org/install/linux>.
3. Install **usbmuxd**: `sudo apt-get install usbmuxd`
4. In your browser, download **Xcode** (the `.xip` file, several GB) from <https://developer.apple.com/download/all/?q=Xcode>. Sign in with your Apple ID.
5. Install xtool:
   ```bash
   curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o xtool
   chmod +x xtool && sudo mv xtool /usr/local/bin/
   ```
6. Run `xtool setup`. Choose **Password** for a free Apple ID, and give it the path to the Xcode `.xip`.

### 2. Prepare your iPhone (one time)

1. Plug it in, unlock it, and tap **Trust This Computer**.
2. Turn on **Settings → Privacy & Security → Developer Mode**. The iPhone restarts.

### 3. Build and install Limitty

```bash
git clone https://github.com/lavickasebastian16/Limitty.git
cd Limitty/ios
xtool dev
```

The first time you open the app, iOS will say the developer is untrusted. Go to **Settings → General → VPN & Device Management**, tap your Apple ID, then tap **Trust**.

> If xtool says the bundle ID is taken, change `bundleID` in `xtool.yml` to something unique to you (for example `com.yourname.limitty`) and run `xtool dev` again.

## Sign in and add the widget

1. Open **Limitty**, tap **Sign in to Claude**, and sign in on the claude.ai page that opens. Do the same for **Codex** (chatgpt.com).
   - Use **email sign-in**. Google and Apple sign-in buttons often refuse to work inside apps.
   - Can't sign in that way? Tap **Paste instead** and paste the cookie from a computer browser. For Claude that's `sessionKey`; for Codex it's `__Secure-next-auth.session-token`, or a Codex `access_token` from `~/.codex/auth.json`.
2. Long-press your Home Screen, tap **Edit → Add Widget → Limitty**, and pick small, medium or large. Lock Screen widgets (circle, rectangle, inline) are there too.

Bars turn amber at 60% and red at 85%. Widgets refresh about every 15–30 minutes; iOS decides exactly when. Opening the app refreshes right away. When offline, the widget keeps the last numbers for up to a day and shows a ⏱ clock icon.

## Free Apple ID limits

- **The app stops opening after 7 days.** Plug in and run `xtool dev` again to renew it. Your logins are kept.
- A free account can have **3 sideloaded apps** at a time, and register **10 app IDs per week**. Limitty uses 2: the app and its widget.

## How it works

- Signing in opens the real claude.ai or chatgpt.com page in the app. Once you're signed in, the app saves that site's cookies.
- The cookies go into an **App Group**, storage shared between the app and its widget. That's how the widget can fetch your limits by itself. xtool registers the App Group automatically.
- Claude limits come from `claude.ai/api/organizations/{id}/usage`. These are the numbers shown in claude.ai's Settings → Usage.
- Codex limits come from `chatgpt.com/backend-api/wham/usage`, the same numbers as Codex's `/status`. The phone gets a fresh access token from your ChatGPT login each time.
- Your logins are only ever sent to claude.ai and chatgpt.com.

## Caveats

- These are the websites' internal endpoints, not public APIs, so Anthropic or OpenAI could change them.
- claude.ai and chatgpt.com use Cloudflare, which sometimes blocks app requests. If you see "refused the request", sign in again. For Codex you can also paste an access token instead.
- The saved cookie is a full login to that account. **Sign out** in Limitty, or sign out on the website, to cancel it.

## Project layout

```
xtool.yml                     app + widget extension config for xtool
Package.swift                 Swift package (targets below)
Sources/LimittyCore/          networking, parsing, shared storage, shared views
Sources/Limitty/              the app: limits list, in-app sign-in
Sources/LimittyWidget/        Home and Lock Screen widgets
Tests/LimittyCoreTests/       tests (run anywhere with `swift test`, including Linux)
```

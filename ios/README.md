# Limitty for iPhone (native app + widgets)

A native SwiftUI app with Home Screen and Lock Screen widgets showing your **Claude**, **Codex** and **Gemini (Antigravity / agy)** usage limits: a bar per limit window, the percentage used, and when it resets.

Download the ready-made `.ipa`, or build it yourself with **[xtool](https://github.com/xtool-org/xtool)** from **Linux or Windows (WSL)**. You don't need a Mac or a paid developer account either way.

## Easiest: install the ready-made .ipa

GitHub builds `Limitty-<version>.ipa` automatically on every change. Download it from the **[latest release](https://github.com/lavickasebastian16/Limitty/releases/tag/latest)**, which also has the Linux builds. It's also attached to each run of the **Build apps** workflow under the repo's **Actions** tab.

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
   - **Continue with Google** now works in more cases: the in-app browser presents itself as Safari for your iOS version and supports Google's pop-up window. Google sometimes still says *"This browser or app may not be secure"*. If it does, go back and use **Continue with email** with your Gmail address; the sign-in code arrives in that inbox, and it's the same account.
   - Still stuck? Tap **Paste instead** and paste the cookie from a computer browser. For Claude that's `sessionKey`; for Codex it's `__Secure-next-auth.session-token`, or a Codex `access_token` from `~/.codex/auth.json`.
2. For **Gemini**, tap **Sign in with Google**. iOS opens its secure Safari sign-in sheet; sign in and allow access. The sheet then shows "Signed in ✓" and closes.
   - **Read this first:** this signs in *as the Antigravity app*, the same way tools like CodexBar do. Google's terms don't allow that, and some people using Antigravity logins in third-party tools have had accounts suspended. **A spare Google account is safest.**
   - If the sheet doesn't come back, use **Open sign-in in Safari instead**. Safari will end on a "can't connect to localhost" page. Copy the link from the address bar and paste it into Limitty.
   - It shows the **Gemini Pro** and **Gemini Flash** quotas, as in agy's `/usage`. Each pool shows its most-used model.
3. Long-press your Home Screen, tap **Edit → Add Widget → Limitty**, and pick small, medium or large. Lock Screen widgets (circle, rectangle, inline) are there too.

Bars turn amber at 60% and red at 85%. Widgets refresh about every 15–30 minutes; iOS decides exactly when. Opening the app refreshes right away. When offline, the widget keeps the last numbers for up to a day and shows a ⏱ clock icon.

## Agent status from your PC

The **Agents on your PC** section, and the **Limitty Agents** widget, show whether Claude Code, Codex and Antigravity on your PC are working, need you, or are idle. Link them by signing in with the **same GitHub account** on both:

1. **PC:** in the Limitty desktop app, open the menu (⋯) → **Connect agents to iPhone…** (or run `npm run agent:setup`), and enter the code on GitHub's page.
2. **iPhone:** **Sign in with GitHub**, tap **Copy code & open GitHub**, paste the code and approve it.
3. **Notifications:** pick a sound for "needs permission" and another for "done". Add the free Bark app there for instant alerts, even when Limitty is closed.

While Limitty is open, the list refreshes every 15 seconds. The widget refreshes when iOS allows, roughly every 5–15 minutes, so rely on the ntfy alerts for "needs you". GitHub sign-in needs a one-time registration; see "Register the GitHub sign-in" in the main README. No GitHub account? **Pair with a QR code instead** still works.

## Tasks for your agents

Under **Tasks**, tap **New task**, describe the work, and pick a project. The CEO on your PC plans it and hands it to Claude Code, Codex or Antigravity. Tap a task to see the plan, each worker's output, and **Cancel** or **Run again**. This needs GitHub sign-in and a connected PC; see "Company" in the main README.

## Free Apple ID limits

- **The app stops opening after 7 days.** Plug in and run `xtool dev` again to renew it. Your logins are kept.
- A free account can have **3 sideloaded apps** at a time, and register **10 app IDs per week**. Limitty uses 2: the app and its widget.

## How it works

- Signing in opens the real claude.ai or chatgpt.com page in the app. Once you're signed in, the app saves that site's cookies.
- The cookies go into an **App Group**, storage shared between the app and its widget. That's how the widget can fetch your limits by itself. xtool registers the App Group automatically.
- Claude limits come from `claude.ai/api/organizations/{id}/usage`. These are the numbers shown in claude.ai's Settings → Usage.
- Codex limits come from `chatgpt.com/backend-api/wham/usage`, the same numbers as Codex's `/status`. The phone gets a fresh access token from your ChatGPT login each time.
- Gemini limits come from Google's Cloud Code service (`daily-cloudcode-pa.googleapis.com`, `fetchAvailableModels`), the same call Antigravity makes. Sign-in uses Antigravity's Google OAuth client with PKCE. Google's reply is caught by a tiny server Limitty runs on the phone's own `localhost:51121` during sign-in only. The refresh token stays on the phone.
- Your logins are only ever sent to claude.ai, chatgpt.com and Google.

## Caveats

- These are the websites' internal endpoints, not public APIs, so Anthropic or OpenAI could change them.
- claude.ai and chatgpt.com use Cloudflare, which sometimes blocks app requests. If you see "refused the request", sign in again. For Codex you can also paste an access token instead.
- The saved cookie is a full login to that account. **Sign out** in Limitty, or sign out on the website, to cancel it.
- To fully cancel Gemini access, also remove "Antigravity" at <https://myaccount.google.com/connections>.

## Project layout

```
xtool.yml                     app + widget extension config for xtool
Package.swift                 Swift package (targets below)
Sources/LimittyCore/          networking, parsing, shared storage, shared views
Sources/Limitty/              the app: limits list, in-app sign-in
Sources/LimittyWidget/        Home and Lock Screen widgets
Tests/LimittyCoreTests/       tests (run anywhere with `swift test`, including Linux)
```

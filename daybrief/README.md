# Daybrief for iPhone

One list of everything you have to do, from five places:

| Source | What it shows | How it connects |
|---|---|---|
| **Apple Calendar** | Events for the next 30 days | iOS permission |
| **Apple Reminders** | Every reminder that isn't done (swipe to mark done) | iOS permission |
| **Obsidian** | Open tasks (`- [ ]`) in your vault, with due dates | You pick the vault folder |
| **EduPage** | Homework, exams and school events | School, username and password |
| **Gmail** | Starred mail and unread mail from the last week | Address and an app password |

Each day you get two notifications:

- **A morning summary** (07:00 unless you change it): what's on today, plus overdue tasks and waiting email.
- **An evening-before warning** (18:00): what's on tomorrow. It only comes when there is something.

Daybrief is a separate app from Limitty. It lives in this repo so the same build makes both.

## Install

GitHub builds `Daybrief-<version>.ipa` on every change. Download it from the **[latest release](https://github.com/lavickasebastian16/limitty/releases/tag/latest)** and install it the same way as Limitty: with Sideloadly, AltStore or SideStore. The steps are in [ios/README.md](../ios/README.md#easiest-install-the-ready-made-ipa).

Or build it yourself with [xtool](https://github.com/xtool-org/xtool) from Linux or Windows (WSL):

```bash
git clone https://github.com/lavickasebastian16/limitty.git
cd limitty/daybrief
xtool dev
```

With a free Apple ID the app stops opening after 7 days until you install it again; your connections are kept. A free account can have 3 sideloaded apps. Limitty uses 2 of them (the app and its widget) and Daybrief uses 1.

## Connect your sources

Open Daybrief and tap **Connect** (later: the gear button).

1. **Apple Calendar and Reminders:** turn on the switches and allow access when iOS asks. For Calendar choose **Full Access**; otherwise iOS doesn't let an app read events.
2. **Obsidian:** tap **Choose vault folder…** and pick the vault folder itself: **On My iPhone → Obsidian → your vault**, or **iCloud Drive → Obsidian → your vault**.
3. **EduPage:** enter your school (the first part of the address: `myschool` for `myschool.edupage.org`), username and password.
4. **Gmail:** Google doesn't accept your normal password from other apps. Turn on 2-Step Verification in your Google account, create an **app password** at <https://myaccount.google.com/apppasswords>, and paste it in.
5. **Daily summary:** choose the two times and allow notifications. **Send a test summary now** shows what one looks like.

### Which Obsidian tasks are found

```markdown
- [ ] Buy milk                              no date → listed under "No date"
- [ ] Essay 📅 2026-11-14                    Tasks plugin: due date
- [ ] Start revision ⏳ 2026-11-14           Tasks plugin: scheduled date
- [ ] Call the dentist [due:: 2026-11-15]   Dataview field
- [ ] Hand in form @due(2026-11-16)
- [x] Done tasks are skipped
```

A task without a date in a daily note (`2026-11-14.md`) counts as due on that day. In a daily note, `- [ ] 09:30 Stand-up` gets that time. Hidden folders (`.obsidian`, `.trash`) and code blocks are skipped.

### Which emails are shown

By default: `is:starred OR (category:primary is:unread newer_than:7d)`, in your inbox. You can change the search under **Gmail** in Connections; it uses [Gmail's search words](https://support.google.com/mail/answer/7190). Daybrief only reads, and nothing is marked as read.

## What to expect

- **Summaries are scheduled ahead.** iPhone apps installed without a paid Apple developer account can't be woken at a set time. So each time Daybrief refreshes (when you open it, and now and then in the background when iOS allows) it schedules the summaries for the next 7 days from what it knows then. Something you add later shows up in a summary after the next refresh. Open Daybrief every few days to keep them current.
- **EduPage has no public API.** Daybrief signs in the way EduPage's own web page does, following the open-source [edupage-api](https://github.com/EdupageAPI/edupage-api) project. EduPage can change that page at any time, and accounts with two-step sign-in aren't supported. This part has only been tested against saved example pages, not a live school account.
- **Your passwords stay on the iPhone**, in its Keychain. The EduPage password is only sent to your school's EduPage, and the Gmail app password only to `imap.gmail.com`. You can delete an app password in your Google account at any time.
- Tapping an item opens it in its own app: Calendar, Reminders, Obsidian (the note), EduPage (the website) or Gmail.

## Project layout

```
xtool.yml                     app config for xtool
Package.swift                 Swift package (targets below)
Sources/DaybriefCore/         parsing (Obsidian, EduPage, Gmail), summaries, the notification plan
Sources/Daybrief/             the app: list, connections, EventKit, notifications
Tests/DaybriefCoreTests/      tests (`swift test`)
```

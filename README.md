# Macky — a voice assistant that lives in your Mac's notch

Macky is a macOS assistant you talk to. You hold a key, say what you want, and it does it —
play a song, send a Slack message, check your calendar, add a reminder, open a website,
read your unread email. No app to open, no typing, no clicking around. **Voice in, action
out.**

It lives in the notch at the top of your screen. When you're not using it, it just looks
like the notch. When you talk to it, a small waveform appears inside the notch; it only
grows into a panel when there's something worth showing you (like the live steps of a
multi-step task).

> This guide is written for someone who has never set the project up before. Follow it top
> to bottom.

---

## Table of contents

1. [What you can ask it to do](#1-what-you-can-ask-it-to-do)
2. [What you need before you start](#2-what-you-need-before-you-start)
3. [Setup — get the app running](#3-setup--get-the-app-running)
4. [First launch — permissions](#4-first-launch--permissions)
5. [Sign in](#5-sign-in)
6. [Connect your apps (Slack, Gmail, Spotify, …)](#6-connect-your-apps-slack-gmail-spotify-)
7. [How to use it every day](#7-how-to-use-it-every-day)
8. [Reading the notch](#8-reading-the-notch)
9. [Settings](#9-settings)
10. [Troubleshooting](#10-troubleshooting)
11. [Privacy](#11-privacy)
12. [For developers: self-hosting the backend](#12-for-developers-self-hosting-the-backend)
13. [Project layout](#13-project-layout)

---

## 1. What you can ask it to do

Just talk normally. Some examples:

- "Play *Bohemian Rhapsody* on Spotify."
- "What's on my calendar tomorrow?"
- "Add a reminder to call the dentist at 4pm."
- "Message Rahul on Slack that the auth bug is fixed."
- "Read my unread email."
- "Open github.com."
- "Turn the volume down and turn on Do Not Disturb."
- "Message Rahul that the bug is fixed, and add a reminder to follow up tomorrow." *(a
  multi-step request — the panel opens and shows each step as it happens)*

You don't configure any of this. The assistant figures out which tools it needs and uses
them while it talks to you.

---

## 2. What you need before you start

- **A Mac running macOS 14.2 or newer.** A Mac with a notch (MacBook Pro/Air, 2021 or
  later) gives the best experience, but Macky also works on Macs without a notch — it shows
  a floating bar at the top of the screen instead.
- **A microphone** (built-in is fine) and **speakers/headphones**.
- **An email address** — you sign in with a one-time link sent to your email.
- **Xcode** (free from the Mac App Store) — this is how you build and install the app from
  this source code. You need this only if you're building the app yourself; if someone gave
  you a ready-made `Macky.app`, skip straight to [section 4](#4-first-launch--permissions).

You do **not** need to set up any servers, API keys, or accounts with Azure/OpenAI to use
the app. The backend it talks to is already hosted. (Setting up your own backend is an
advanced, optional step covered in [section 12](#12-for-developers-self-hosting-the-backend).)

---

## 3. Setup — get the app running

You have two paths. Most people will use Path A.

### Path A — You were given a ready-made app

1. Drag **`Macky.app`** into your `Applications` folder.
2. Double-click to open it. The first time, macOS may warn that it's from an unidentified
   developer or downloaded from the internet — right-click the app, choose **Open**, then
   confirm.
3. Skip to [section 4](#4-first-launch--permissions).

### Path B — Build it yourself from this source code

1. **Install Xcode** from the Mac App Store if you don't have it.
2. **Open the project.** In Finder, double-click `leanring-buddy.xcodeproj` (the folder
   name has an intentional typo — leave it as is). Or from Terminal, in the project folder:
   ```bash
   open leanring-buddy.xcodeproj
   ```
3. **Wait for dependencies.** The first time you open it, Xcode automatically downloads a
   few packages (Sparkle and PostHog). Give it a minute. You can watch the
   progress in the top toolbar.
4. **Pick the app.** In the toolbar near the top-left, make sure the scheme selector says
   **`leanring-buddy`** and the target is **My Mac**.
5. **Build and run.** Press the ▶ button (or `Cmd + R`). Xcode compiles the app and
   launches it.

When it launches, you won't see a normal window — Macky runs as a background app, and its
UI appears at your notch. Continue to the next section.

---

## 4. First launch — permissions

Macky needs three macOS permissions to work. macOS will ask for them, or you can grant them
in **System Settings ▸ Privacy & Security**:

| Permission | Why Macky needs it | If you skip it |
|------------|--------------------|----------------|
| **Microphone** | To hear what you say. | No voice input at all. |
| **Accessibility** | To detect the global push-to-talk shortcut even when another app is focused. | The hold-to-talk key won't work. |
| **Screen Recording** | So it can look at your screen when you ask about what's on it. | It just can't see your screen; voice still works. |

**To grant Accessibility** (the one people most often miss): open **System Settings ▸
Privacy & Security ▸ Accessibility**, find **Macky** (or `leanring-buddy`) in the list, and
turn the toggle **on**. You may need to quit and reopen the app afterward.

> Tip: if the push-to-talk key isn't doing anything, Accessibility is almost always the
> reason. Double-check that toggle.

---

## 5. Sign in

1. Look at your notch — Macky shows a small sign-in panel.
2. Type your **email address** and click **Send magic link**.
3. **Check your email.** You'll get a message titled *"Your Macky sign-in link"* with a
   **Sign in to Macky** button. (Look in spam if you don't see it within a minute.)
4. **Click the link.** It opens in your browser for a moment, then bounces back into the
   Macky app and finishes signing you in automatically.
5. That's it — your session is saved securely in your Mac's Keychain, so you stay signed in.

The link expires in 15 minutes and can only be used once. If it expires, just click
**Resend** in the app.

---

## 6. Connect your apps (Slack, Gmail, Spotify, …)

Macky reaches your apps in two ways, and both connect the first time you need them:

- **Apple apps (Calendar, Reminders, Mail, etc.)** use the normal macOS permission popups.
  The first time you ask Macky to read your calendar or add a reminder, macOS asks you to
  allow it. Click **Allow**.
- **Web apps (Slack, Gmail, Spotify, GitHub, Notion, Linear, and 250+ more)** connect
  through a secure link. The first time you ask Macky to do something with, say, Slack, it
  gives you a **connect link**. Open it, sign in to that service once, and approve access.
  After that, Macky remembers it — you never have to reconnect.

You don't need to set all of this up in advance. Connect each app the moment you first use
it.

The integrations that work best today: **Spotify, Apple Calendar, Apple Reminders, Slack,
Gmail, Chrome/browser, and system controls** (volume, Do Not Disturb, lock screen).

---

## 7. How to use it every day

1. **Hold the push-to-talk shortcut.** By default this is a modifier-key combo such as
   **Control + Option** (you can change it — see [Settings](#9-settings)). Hold the keys
   down.
2. **Speak** while holding. A dim waveform appears in the notch reacting to your voice.
3. **Let go** when you're done talking.
4. **Listen.** Macky starts answering almost immediately — often before you've fully
   released the key. It talks back through your speakers, and runs any tools it needs in the
   background while it speaks.

A few things worth knowing:

- **Interrupt anytime.** If Macky is talking and you want to say something new, just hold
  the shortcut again — it stops and listens to you.
- **Simple requests stay in the notch.** "Play a song" or "set a reminder" happen quietly
  with no panel — you just hear the confirmation.
- **Multi-step requests open a panel** that lists each step live (a spinner on the current
  step, a checkmark when it finishes), then collapses when done.
- **Hover the notch** to peek at what it's doing or its last action.

---

## 8. Reading the notch

| What you see | What it means |
|--------------|---------------|
| Just the notch, nothing moving | Idle — waiting for you. |
| Dim waveform inside the notch | Listening to you. |
| Soft slow pulse | Thinking. |
| Quiet waveform | Speaking back to you. |
| Notch grows into a panel with a list of steps | Doing a multi-step task; each line updates live. |
| Panel on hover | You're peeking at its status. |

On a Mac **without** a notch, the same thing appears as a small bar pinned to the top-center
of your screen.

---

## 9. Settings

- **Change the push-to-talk shortcut:** open the Macky panel (hover the notch), go to the
  hotkey setting, and **hold a new modifier combo** (for example, Control + Option), then
  release to save. Macky supports modifier-only shortcuts, so you don't need a letter key.

---

## 10. Troubleshooting

**The hold-to-talk key does nothing.**
Grant **Accessibility** permission (System Settings ▸ Privacy & Security ▸ Accessibility,
turn Macky on), then quit and reopen the app. This is the #1 cause.

**It can't hear me.**
Check **Microphone** permission, and make sure the right input device is selected in System
Settings ▸ Sound.

**It can't see my screen when I ask about it.**
Grant **Screen Recording** permission, then restart the app.

**I never got the sign-in email.**
Check spam. The link is also valid for only 15 minutes — click **Resend** in the app to get
a fresh one. Make sure you typed your email correctly.

**The sign-in link opened my browser but didn't return to the app.**
Make sure Macky is installed and running, then click the **Open Macky** button on that
browser page.

**It says it can't connect / nothing responds.**
Check your internet connection. Macky needs to be online to hear and answer you.

**I don't see anything at my notch.**
Macky runs in the background with no Dock icon. Make sure it's actually running (relaunch
from Xcode or from your Applications folder), and look at the very top-center of your
screen.

---

## 11. Privacy

- Apple apps (Calendar, Reminders, Mail, etc.) are handled **locally on your Mac**.
- Your microphone is only active while you **hold** the push-to-talk key.
- Screenshots are taken **only when you ask** something about your screen — never
  continuously, and there's no always-on recording.
- Your sign-in session is stored in your Mac's **Keychain**.
- Macky does not keep a persistent memory of your activity across sessions.

---

## 12. For developers: self-hosting the backend

**You can skip this entirely if you just want to use the app** — it already talks to a
hosted backend.

The app never talks to AI providers directly. A small **Cloudflare Worker** (in `worker/`)
sits in between, holds the secrets, and proxies the realtime voice connection. The app
points at a hosted Worker whose host is defined in **one** place in the Swift code
([`leanring-buddy/WorkerEndpoints.swift`](leanring-buddy/WorkerEndpoints.swift)). To run
your own:

1. Read [`worker/AGENTS.md`](worker/AGENTS.md) for the full route and secret list.
2. From `worker/`, authenticate and create the token store:
   ```bash
   npx wrangler login
   npx wrangler kv namespace create AUTH_TOKENS
   npx wrangler kv namespace create AUTH_TOKENS --preview
   ```
   Paste the returned ids into `worker/wrangler.toml`.
3. Set the secrets (you supply your own provider keys):
   ```bash
   npx wrangler secret put AZURE_OPENAI_API_KEY   # realtime voice model
   npx wrangler secret put COMPOSIO_API_KEY       # web-app integrations gateway
   npx wrangler secret put RESEND_API_KEY         # sends the sign-in email
   ```
4. Deploy:
   ```bash
   npx wrangler deploy
   ```
5. Point the app at your Worker by changing the single `baseHost` constant in
   [`leanring-buddy/WorkerEndpoints.swift`](leanring-buddy/WorkerEndpoints.swift), then
   rebuild. Every Worker URL the app uses — the realtime socket, the Composio config
   fetch, the connector connect/connections calls, and the magic-link auth routes — derives
   from that one host, so there is nothing else to update.

To package and ship a signed, notarized release, see [`scripts/AGENTS.md`](scripts/AGENTS.md).

---

## 13. Project layout

| Folder | What's in it |
|--------|--------------|
| [`leanring-buddy/`](leanring-buddy/) | The macOS app source (notch UI, voice, integrations). The folder name is intentional legacy. |
| [`leanring-buddy.xcodeproj/`](leanring-buddy.xcodeproj/) | The Xcode project you open to build the app. |
| [`worker/`](worker/) | The Cloudflare Worker backend (proxy + sign-in). |
| [`scripts/`](scripts/) | Release automation (build, sign, notarize, publish). |
| [`MACKY.md`](MACKY.md) | The product vision and design brief. |

Each folder also has an `AGENTS.md` with deeper technical context for contributors and AI
coding agents. Start with the root [`AGENTS.md`](AGENTS.md).

# OLED

A native macOS voice assistant (Swift + SwiftUI). Say **“OLED”** (O-L-E-D) or click the orb, then speak.

## What it does

- **Chat** – ask anything and OLED answers out loud (needs a Claude API key in Settings).
- **Open apps** – “OLED, open Spotify”.
- **Open websites** – “OLED, open YouTube” → OLED asks “Firefox or Safari?” → answer and it opens there.
  You can also say “open YouTube in Firefox”.
- **Keyboard** – “OLED, press Command T”, “OLED, type hello there”.

## Install

1. Download **OLED.dmg** from the [latest release](../../releases/latest).
2. Open it and drag **OLED** into **Applications**.
3. First open: macOS may say it can't check the app. Go to **System Settings → Privacy & Security**,
   scroll down and click **Open Anyway** (only needed once).
4. Follow the two setup steps: allow the **microphone**, then switch on **Accessibility** for OLED.

## Settings (Command-comma)

- British voice choice and a Human ↔ Robotic slider
- Claude API key for conversation
- Re-run setup / open Accessibility settings

## App icon

Add a square PNG at `Resources/AppIcon.png` (1024×1024 ideally). The next build uses it automatically.

## Building

Every push to `main` builds the app on GitHub's Mac machines and publishes `OLED.dmg` as the latest release.
To build on a Mac instead: `./scripts/build_app.sh` (needs Apple's command-line tools).

# HUD — Desktop Floating Window Framework (based on TrollSpeed, MIT)

This directory holds the floating-window (HUD) framework source and private headers originally from **TrollSpeed** (https://github.com/Lessica/TrollSpeed, MIT License, Copyright (c) 2023 Lessica), integrated into TrollAgent for the desktop floating mascot.

## Architecture
- `HUDApp.mm` — the HUD standalone process's `main` (`-hud` argument branch; initializes its own UIApplication)
- `HUDMainApplication.mm` — the HUD's UIApplication subclass (installs a HID event source, receives touches)
- `HUDMainWindow.mm` — global system window (`_isSystemWindow` and other private methods)
- `HUDHelper.mm` — process spawn + persona handling for launching the HUD
- `MainApplication.mm` / `MainApplicationDelegate.mm` — main-app entry and spawn trigger (reference)
- `headers/` — private framework headers (UIAutoRotatingWindow / UIEventDispatcher / SBSAccessibilityWindowHostingController etc.)
- `supports/entitlements.plist` — HUD process system-level entitlements (persona-mgmt / no-sandbox / hid.client / springboard.accessibility-window-hosting etc.)

## Copyright
TrollSpeed is MIT-licensed; the core framework is used directly with its original copyright notice preserved. Files in this directory keep the original author's header comments.

## Integration (this project's choice)
The main app (SwiftPM Swift project) and the HUD are separate:
- HUD is a **standalone binary**, compiled with theos (see the TrollSpeed Makefile; build only the HUD part), signed independently with `supports/entitlements.plist`
- The main app's Settings has a "Desktop Floating" toggle that launches the HUD binary
- The HUD window shows the mascot's multi-frame animation (reads `girl_*.png` / `cat_*.png` etc. from the main app bundle)

> Note: the historical `posix_spawn + root persona` launch path hit the known "spawn -106" wall on iOS 16 + TrollStore (non-platform codesign); the current implementation uses the working launch route and keeps the HUD in the main app's lifecycle. HUD bubble quotes are bilingual (reads `/var/mobile/Documents/app_language.txt`).

# HUD Desktop Floating — Progress Snapshot (archived)

- Date: 2026-10-07 → resolved 2026-10-11+
- Status: **resolved**. The floating mascot ships and works; bubble quotes are bilingual (see HUD/README.md). This file keeps the investigation record only.

## Verified Facts (device)

1. Entitlements were complete: platform-application / no-sandbox / accessibility-window-hosting / get-task-allow / persona-mgmt / launchd.job-manager / launchd.job-submission — the old "spawn -106" was **not** an entitlements problem.
2. `launchctl` unusable from the app: spawn ENOENT; /usr/bin /usr/sbin /bin /sbin /usr/libexec all missing from the app's view.
3. `posix_spawn` with persona 99 → -106: iOS 16 + ldid-injected platform-application isn't a real platform codesign → privilege elevation denied (known limit).
4. No OpenSSH on the phone; the 8790 endpoint is the app's remote terminal, not a real system shell.

## Root Cause & Direction Change

- The old -106 = trying to **launch a standalone HUD process** (needs launchd/root, which this iOS 16 won't grant). Correct approach = **in-app floating window + background keep-alive**, no standalone process, no launchd/root/libxpc.
- Step 1 verified: HUD launch switched to **non-elevated posix_spawn** → errno 106 completely avoided; `hud.log: start OK (posix_spawn, mobile)`; HUD process visible in ps.
- Step 2: HUD window mechanism refactored from the TrollSpeed plugin mode (GSInitialize + BKSDisplayServicesStart + UIApplicationInitialize + plugin event takeover — needs root persona) to **a normal UIApplication + high-windowLevel accessibility global window** (TheBall way, works as mobile).
- TheBall reverse conclusions used: in-app `FloatingContentViewController` + `floatingWindow` (high windowLevel); covering the desktop = accessibility window hosting (springboard.accessibility-window-hosting + physicalinteraction.client + assistivetouch.daemon + AXEventRepresentation); background keep-alive = `UIBackgroundModes: processing` + `beginBackgroundTask`.

## References

- TheBall source/ipa: `research/TheBall/`
- TrollSpeed reference (launchctl/persona route, confirmed infeasible on this device): `research/TrollSpeed/`
- Repo: zrrt/TrollAgent (main)

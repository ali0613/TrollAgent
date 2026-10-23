# VPN Capture Development Log (archived 2026-10-03, current state 2026-10-23)

> Historical context file. Everything here was device-verified at the time. Full details live in git history; this file keeps only the conclusions that still govern the code.

## Current State (what still applies)

- **VPN capture = VpnTunnel.appex starts the tunnel directly with its own entitlements** (no-sandbox + platform-application + task_for_pid). The kfd-injection coupling was removed: `startVpn` no longer requires/triggers trust injection.
- **Black-screen root cause (conclusive)**: the Fuck-style kfd injection engine (`fuck_helper`, libkfd landa/smith/physpuppet) computes physical addresses unreliably on this iOS 16.3 build → writes into the kernel static region → kernel panic → black screen + reboot. Not an entitlements/permissions difference — an exploit-adaptation mismatch for the build.
- `fuck_helper` trusts **itself** (spawns, then elevates + adds its own cdhash to the trust cache). It cannot be targeted at VpnTunnel → cdhash/target mismatch → panic. Hence injection was unbundled from VPN.
- kfd injection (`injectNow` / `inject` subcommand / UI inject button) remains as a standalone advanced capability (trust self / inject dylibs), decoupled from VPN.
- Known gap (P2 config chain): VpnTunnel reads `com.ai.iosxcode.packet-tunnel.start-state` (CFPreferences suite) + `group.com.ai.iosxcode` AppGroup + `MitmService` (TunnelServices decrypt engine). The main app historically never wrote that suite — the capture-config chain must be verified. Until then, `local_start` (127.0.0.1:18180 + WiFi manual proxy, zero black-screen risk) is the reliable fallback.

## Dead Ends (don't retry)

- native python3 fork/exec → Errno 45
- writing files from the bundle at runtime → Permission denied
- iOS native `find /var/containers… -name "*.app"` returns empty (find bug)
- Alpine can't run arm64 iOS binaries
- kfd auto/manual injection to start VPN = black screen (engine unstable on this build)

## Verified Facts (device, 2026-10-03)

- Device: iPhone 14,3, iOS 16.3, TrollStore (no jailbreak)
- App installed as `TrollAgent.app`; real path under `/private/var/containers/Bundle/Application/<UUID>/TrollAgent.app/`
- VpnTunnel: `PlugIns/VpnTunnel.appex/VpnTunnel` (155,315 B)
- Panic logs: `/var/mobile/Library/Logs/CrashReporter/panic-full-*.ips` — `Panicked task pid 702: fuck_helper` + `Unexpected fault in kernel static region`
- VpnTunnel entitlements confirmed: no-sandbox=1 / platform-application=1 / task_for_pid-allow=1 (from install logs)

## Release

`https://github.com/zrrt/TrollAgent/releases/download/latest/TrollAgent.tipa`

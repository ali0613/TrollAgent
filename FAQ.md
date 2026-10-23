# TrollAgent FAQ

> Version: v7.0.4+ (iOS 16.3 / TrollStore). Check here first when something goes wrong.

## 1. JIT & Performance

### Q1: Why does TrollAgent need JIT?
The unified environment (TrollRuntime) uses the Asbestos translator to translate Linux ARM64 instructions for execution on the iPhone. Without JIT it runs in pure interpreted mode — usable but very slow (v7.0.1 hung in practice); with JIT, translated blocks are cached as native code and speed improves by an order of magnitude (uname dropped from seconds to ~47ms).

### Q2: Does JIT turn on automatically?
Yes. Since v7.0.4 the app does two things at launch (double insurance):
1. **ptrace self-attach** (in-process attempt, invisible, no app switching)
2. **Unconditional TrollStore URL** (`apple-magnifier://enable-jit`, external attach with TrollStore root privileges — this is the reliable path)

It also waits 3 seconds before the first shell command to make sure the JIT authorization is ready.

### Q3: Why can't the app enable JIT entirely by itself?
On iOS **a process cannot synchronously debug itself** (Husk official docs: "A process cannot synchronously debug itself"). For the kernel to allow executable memory, **another process** (debugger / root helper) must attach to the target app. Therefore:
- Self-ptrace (self-attach): may report success but the kernel never actually allows JIT → writing JIT code pages later causes **SIGBUS (Bus error: 10)** crashes
- TrollStore URL: attached externally by TrollStore's root helper, the grant is effective (v7.0.3 manual JIT test: 29/29 passed)

### Q4: It crashes after opening / crash log shows "signal Bus error: 10" — what now?
SIGBUS = the kernel refused access to JIT memory (KERN_PROTECTION_FAILURE), meaning JIT authorization didn't take effect. Troubleshoot in order:
1. Make sure you run the latest build (≥ v7.0.4.2, double-insurance fix)
2. Before opening the app, manually enable **"Allow JIT"** once in **TrollStore** (acts as a fallback grant)
3. Confirm **Developer Mode** is enabled (iOS 16+ prerequisite for JIT; TrollStore normally handles it during install)
4. If it still crashes, share the crash log (in-app: Tool Audit → Crash Logs tab, or iOS Settings → Analytics Data → `TrollAgent-*.ips`)

### Q5: Do I have to enable JIT manually every launch?
No. Since v7.0.4.2 it enables automatically (double insurance + wait before the first command). The TrollStore manual toggle is only a fallback.

## 2. Remote Terminal / Connection

### Q6: How do I start the remote terminal service?
**Settings → Network & Capture → Remote Terminal Service → tap "Start"** (shows "started :8790"). Note: the service is **started manually**; after reinstall it defaults to off and won't auto-start.

### Q7: The app shows the service running but I can't connect — why?
Two most likely causes:
1. **App went to the background**: iOS suspends a backgrounded app's network service within seconds. Keep the app in the foreground (or enable capture VPN keep-alive) to connect.
2. **Wrong port**: on the LAN connect directly to `http://<phone-IP>:8790`; through the N1 public forwarding it's **18790** (`http://<N1-public-IP>:18790`), not 8790.

### Q8: Where do I find the connection address?
The in-app remote terminal service page shows `http://<phone-IP>:8790` and the token. API: `POST /api/tool`, body `{"name":"shell.exec","params":{"command":"...","timeout":N,"runtime":"ios"}}`, Header `Authorization: Bearer <token>`. `/health` needs no auth and reports liveness.

### Q9: Why can't I connect remotely after installing the capture VPN?
The capture VPN's tunnel route residue "black-holes" LAN inbound traffic to 8790. Turn off the VPN → fully kill and reopen the app → restart the remote terminal service.

## 3. Unified Environment

### Q10: Is TrollRuntime a simulator?
No. It's not the iSH simulator; it's the **unified environment**: Alpine Linux rootfs + Asbestos translator (guest ARM64 → native/interpreted execution). Full shell composition is supported (pipes / `&&` / `;` / loops / redirection), and missing tools auto-install via `apk add`.

## 4. Install / Update

### Q14: How do I install it?
Download the `.tipa` → TrollStore → Install → Open. Upgrading preserves configuration (same bundle id overwrite).

### Q15: Will settings be lost after upgrading?
No. Config lives in UserDefaults / the Documents directory and survives overwrite installs. If something is off (e.g. port in use), just restart the app.

## 5. UI / Features

### Q16: What does the terminal button in the chat input open?
A simple terminal (black background, `$` prompt, runs in the unified environment, 30s timeout) — consistent with the minis real terminal. The remote terminal settings page is still at Settings → Network & Capture.

### Q17: The "Clear" button on the crash-logs tab does nothing?
Fixed in v7.0.4 (added the tab3 branch + clear logic). Update to the latest build.

### Q18: The usage-stats page (chart icon) crashes on tap?
Fixed in v7.0.4 (`%@`+Int format crash changed to `%d`). Just update.

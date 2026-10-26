# TrollAgent

**AI-driven iOS experimentation & QA workbench for TrollStore** — Swift + SwiftUI + SwiftPM, runs on iOS 15+ under TrollStore, ships **37 native tools, 100+ subcommands**, all callable by AI through natural language.

> Zero-learning mode: just say it in plain words ("analyze how this app works", "is this plugin safe", "capture this app's traffic") — the AI picks the tools, installs dependencies, does the job, and gives you a one-line human answer.

---

## Table of Contents

- [Project Overview](#project-overview)
- [Architecture](#architecture)
- [Technology Stack](#technology-stack)
- [Project Structure](#project-structure)
- [Module Details](#module-details)
- [Technology Integration Roadmap](#technology-integration-roadmap)
- [Build](#build)
- [Related Docs](#related-docs)

---

## Project Overview

**TrollAgent** is an AI-driven workbench for the TrollStore ecosystem: it wraps iOS injection, app analysis, decryption, traffic capture, cross-app UI control, device spoofing and more into a set of **native tools callable by AI through natural language**, plus an always-on floating AI voice companion (HUD) over any app.

### Core capabilities

| Area | Description |
|---|---|
| Tool system | 37 native tools, 100+ subcommands, single registration hub |
| Unified execution env | Built-in TrollRuntime (unified Linux userspace); the AI can `apk add` any Linux tool and read iOS files directly |
| AI chat | Multiple upstream models (OpenAI-compatible / Anthropic Messages), SSE streaming, reasoning control, skill system |
| HUD companion | Separate-process floating window (loli / bunny-girl / cat-girl), full voice loop: STT → AI → Edge TTS |
| Remote ops | Gateway WebSocket pairing, SSH tunnel, built-in HTTP terminal, GitHub Actions build & artifact fetch |

### Design principles

- **Zero-learning mode**: natural language straight to results; the AI selects tools and installs dependencies by itself
- **Clean failure boundaries**: high-priority tools return unified `error_code / reason / next_step`, no misleading errors
- **Recoverability**: failed injections auto-rollback + launch self-check (auto-restore on crash)
- **Nativization direction**: progressively retiring iSH/Alpine emulation layers toward aarch64 Linux ELF running directly (see [Roadmap](#technology-integration-roadmap))

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│                    UI layer (SwiftUI)                       │
│  ChatView · SettingsView · BrowserView · GatewayView ·      │
│  CleanupView · FakeDeviceView · ControlCenterView · ...     │
└──────────────────────────┬─────────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────────┐
│               AI chat kernel (OpenAIClient)                 │
│  Multi-upstream models · SSE streaming · reasoning control ·│
│  skill system · batched tool selection                      │
└──────────────────────────┬─────────────────────────────────┘
                           │ tool dispatch (ToolRegistry / MCPCore)
┌──────────────────────────▼─────────────────────────────────┐
│            Tool Registry (37 tools / 100+ subcommands)      │
│  inject · app · file · db · browser · control · device ·    │
│  web · network · vpn · github · tool.install · ...          │
└───┬──────────┬──────────┬───────────┬──────────────────────┘
    │          │          │           │
┌───▼───┐ ┌───▼───┐ ┌────▼────┐ ┌────▼────┐
│Injection││Decrypt ││ Browser ││ Control │
│engine   ││engine  ││WKWebView││Agent.dylib│
│(TrollFools)│(Decrypt)││+JS inject││         │
└───┬───┘ └───┬───┘ └────┬────┘ └────┬────┘
    │         │          │           │
┌───▼─────────▼──────────▼───────────▼───────────────────────┐
│            TrollRuntime (unified Linux userspace)           │
│  Asbestos interpreter · full Alpine toolchain · iOS file    │
│  auto-bind · aarch64 binaries via 3 channels (bundled /     │
│  CI cross-compiled / self-written dylib)                    │
└──────────────────────────┬─────────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────────┐
│              System base (TrollStore mechanics)             │
│  setuid root toolchain (ldid/optool/insert_dylib/ct_bypass) │
│  trollstorehelper silent install · JIT double-ensure · TCC  │
└────────────────────────────────────────────────────────────┘
```

- **Single registry**: every tool registered in one place (`MCPCore.swift`), fully enabled by default
- **Unified execution env**: built-in TrollRuntime (Asbestos interpreter, full Alpine toolchain); iSH retired
- **JIT double-ensure**: ptrace self-attach (silent) + unconditional TrollStore URL (`apple-magnifier://enable-jit`); waits 3s before the first shell command
- **Native tool channels**: bundled binaries / GitHub Actions cross-compilation / self-written dylibs (`inject load_dylib`)
- **TrollStore mechanics**: bundled setuid root toolchain; silent install via trollstorehelper; TCC entitlements passthrough (mic / speech recognition without prompts)
- **HUD separate process**: `ch.xxtou.hudapp` independent binary embedded as a sub-package; App Group shared config; voice loop runs fully on-device

---

## Technology Stack

| Dimension | Detail |
|---|---|
| Languages | Swift (main app / tools / AI kernel), Objective-C++ (HUD window), C (CHev/CISH/CLaunch/CMitm bridge components) |
| UI | SwiftUI (iOS 15+), full Simplified-Chinese / English bilingual switching |
| Platform | iOS 15+ / TrollStore (jailbreak-friendly) |
| Dependency mgmt | SwiftPM |
| Runtime env | TrollRuntime unified Linux userspace (Asbestos interpreter + Alpine toolchain); roadmap target: aarch64 Linux ELF running directly |
| External integration | GitHub Actions (CI build), Edge TTS (speech), multi-upstream LLMs (OpenAI-compatible / Anthropic) |
| Process model | Main app + HUD independent sub-process (`NSPrincipalClass=HUDMainApplication`) |
| Injection system | TrollFools-aligned strategy (dylib inject/remove/backup-rollback), in-memory injection (opainject), ControlAgent.dylib cross-app control |

---

## Project Structure

```
TrollAgent/
├── Sources/TrollMCP2/            # Main project (136 Swift files)
│   ├── AppMain.swift             # Entry point
│   ├── MCPCore.swift            # Tool registry hub (single registration table)
│   ├── Models.swift             # AI chat kernel (tool selection / batching / execution loop)
│   ├── OpenAIClient.swift       # Multi-upstream model client (SSE / usage stats)
│   ├── ChatView.swift           # Chat UI (model picker sheet)
│   ├── SettingsView.swift       # Settings page
│   ├── BrowserManager.swift     # WKWebView + JS-injection browser
│   ├── DecryptEngine.swift      # App decryption engine (memory dump → repackaged ipa)
│   ├── ControlTools.swift       # Cross-app UI control (ControlAgent)
│   ├── CleanupTools.swift       # System cleanup
│   ├── GatewayClient.swift      # Gateway WebSocket pairing
│   ├── GitHubAccountStore.swift # GitHub Actions build / artifact fetch
│   ├── AppPickerView.swift      # App picker (search / category / index)
│   ├── GirlCompanion.swift      # Desktop companion character logic
│   └── ... (tools split by domain: AppTools/FileDbTools/BridgeTools/...)
├── HUD/                         # Floating companion (Objective-C++)
│   ├── sources/HUDRootViewController.mm  # Voice loop / character animation
│   ├── HUD/Resources/           # Character assets (loli / bunny-girl / cat-girl)
│   └── supports/entitlements.plist
├── CHev/ CISH/ CLaunch/ CMitm/  # C bridge components
├── scripts/                     # Build scripts (build-ipa.sh etc.)
├── Resources/                   # Assets
├── Support/Info.plist           # Version (CFBundleShortVersionString)
├── benchmark/ build_out/        # Benchmarks / build output
└── *.md                         # Docs (README/GOALS/DEV_HANDOVER/FAQ...)
```

---

## Module Details

### 🧩 Injection & automation (TrollFools-aligned)
- `inject` (enable / disable / remove / restore / enable_persisted / status / inspect / list): dylib injection, removal, backup-restore with automatic `.bak_macho` rollback
- `inject verify`: post-injection health check (Mach-O load commands + process liveness + crash detection); `inject static`: Mach-O static analysis
- `inject mem`: in-memory injection (opainject, zero file residue); `hook_apply` / `probe_inspect`; `inject load_dylib`: load your own dylib
- `rescue` (scan / recover_all / cleanup): emergency recovery against "app won't open after injection"
- Failed injections auto-rollback + post-injection launch self-check (auto-restore on crash)

### 📱 App management
- `app` (launch / stop / restart / status / stats): process control (3-tier start fallback: `open -b` → direct exec → url scheme)
- `app diagnose`: auto root-cause for launch failures (injection residue / encryption / signature / crash scene → explicit `next_step`)
- `app install / uninstall / duplicate`: AI install / uninstall / duplicate (silent install via trollstorehelper first)
- `app encrypt_info / decrypt / replace_decrypted / restore_binary`: built-in decryption engine (`task_for_pid` + `vm_read` memory dump → rebuilt decrypted image → packaged ipa)
- `app entitlements / deps / cache_inspect / cache_clear / launch_options / inject_package`
- `inject ipa_inspect / dylib_inspect`: IPA/dylib parsing (arch / signature / entitlements / dependencies)

### 🧹 System cleanup
- Storage ring card + 6 cache categories + quick/advanced cleanup tabs + one-tap cleanup (setuid root full-directory rebuild)

### 📂 Filesystem & data
- `file` (inspect / analyze): native file inspection (auto-binds `file` + `strings` in the unified environment)
- `db` (list / schema / query): read app data containers directly via native sqlite3
- `package` (inspect / unpack): deb/ipa unpacking (ar/tar/zip)
- `artifact` (read / write / list): workspace file management
- `container` (refresh / resolve / write / delete): container resolution and read/write

### 🌐 Browser (WKWebView + JS injection, Playwright-style)
- `browser` (status / navigate / screenshot / snapshot / text / click / type / submit / scroll / wait / wait_for) + absolute XPath for elements
- `browser form_fields / fill_form`: full-form autofill (React/Vue-compatible value setter + events)
- `browser adblock / clear`: ad/tracker blocking (WKContentRuleList) + cache/Cookie clearing; `navigate` supports `fresh=true` to bypass cache

### 🎮 Device spoofing (GreenShield-style)
- `device fake / restore`: in-memory FakeDevice.dylib to spoof UIDevice model (zero residue, resets on reboot)
- `device advertising / idfv`: ad identifiers / IDFV; `inject keychain_wipe`: keychain cleaning

### 🛡️ Security detection
- `device info / probe / snapshot`: full checks for TrollStore / task_for_pid / container read-write / injection toolchain

### 🔌 Cross-app UI control
- `control` (inject / status / ui_tree / screenshot / tap / swipe / type / key / tap_text / type_text)
- Injects ControlAgent.dylib → localhost:4789 HTTP API (/status /ui_tree /tap /swipe /type)

### 🏗️ Build & engineering
- `tool.install`: unified tool install loop — one-click in the unified environment (apk→pip→CI; CI cross-compiles native iOS binaries best-effort)
- `env.setup_re`: one-click reverse-engineering toolchain (binutils/file/python3/sqlite/tcpdump/7z…)
- `github` (account_status / trigger_build / fetch_runs / download_artifact): trigger GitHub Actions, watch progress, grab artifacts — the CI builds and ships TrollAgent.tipa
- `project`: workspace project management; `macro` (record / run / list / delete / export): recordable repeatable operations

### 🤖 AI & models
- Multiple upstream models (OpenAI-compatible / Anthropic Messages), SSE streaming word-by-word output, reasoning intensity control
- Tool batching: read-only/query tools batch (up to 4, executed sequentially); state-changing/write tools run one at a time (double-layer safety)
- Skill system: `skills.list` / `skills.read` / `skills.set_enabled` (reusable standard workflows)

### 📡 Gateway & automation
- Gateway WebSocket pairing, multi-node calls, `automation` (run / list / jobs / stop / status / history / set_enabled), `ssh` (exec / scp), `server` (start / stop / status)
- **Remote terminal service**: built-in HTTP terminal on `127.0.0.1:8790` (/api/tools), reachable from a browser or via SSH tunnel

### 📊 Network & diagnostics
- `web.search` (multi-engine fallback Bing→DuckDuckGo→Baidu, parallel `queries`, source-graded `sort`, results into knowledge base via `save`)
- `web.fetch` (auto article extraction, article/main first + built-in browser fallback)
- `network.capture` (start / stop / requests / analyze): NSURLSession capture via injected NetworkTweak; TLSHook decrypts SSL_read/SSL_write
- `vpn.capture`: system-proxy capture — the reliable path is the local proxy (WiFi manual proxy `127.0.0.1:18180`)
- `diagnose` (startup / injection), crash log parsing, `verify` (file / app_running)

### 📚 Knowledge & system
- `knowledge` (import_text / import_file / search / delete / clear): knowledge base CRUD
- `memory` (search / modify / freeze), `assistant_memory` (cross-session memory)
- `location` (get / fake / status / clear), `reminder` (create / schedule / recurring)

### 🐰 Desktop companion (HUD)
- Floating anime companion (loli / bunny-girl / cat-girl) on top of any app: idle frames, wall-climbing, bubble chat
- Full voice loop: STT → AI → Edge TTS; speech-animation reset, sitting/voice-hold pose assets
- 200+ bilingual bubble lines (time greetings, weather, moods, interactions) that follow the app language setting
- Quick menu to launch WeChat / Douyin / AI chat / hide, resizable, draggable, multi-gesture interactions

---

## Technology Integration Roadmap

**Long-term goal** (see [GOALS.md](GOALS.md)): **full nativization** — abolish the iSH/Alpine dual-track routing, ultimately run aarch64 Linux ELF directly so the AI perceives a single environment.

| Phase | Status | Notes |
|---|---|---|
| P1 Unified userspace | ✅ done | TrollRuntime (Asbestos interpreter) took over; iSH emulation retired |
| P2 Dual-track routing convergence | ✅ done (v6.6.0) | Routing abolished + unified env layer landed: runtime param removed, ISHEngine → TrollRuntimeEngine, iSH copy cleared; CELF/elf-runner/static busybox retired |
| P3 Full nativization | 🎯 target | aarch64 Linux ELF running directly; the AI perceives a single environment (N1 gateway LAN tunneling for debugging) |
| Supporting | ongoing | Tool batching for throughput, HUD voice loop, versioned build & release (7.1.x auto-bump) |

### Recent milestones (7.1.x)
- **7.1.88-90**: HUD voice-loop polish (wall-climb guard fix, back-to-idle after playback, bunny-girl sitting pose asset fallback)
- **7.1.91-97**: UI detail fixes (app icons fill rounded corners, device-spoofing picker, model navigation chain)
- **7.1.98**: usage-stats token display (real `usage` preferred)
- **7.1.99-103**: tool batching for throughput (read-only batch ≤4, interpreter batching with script blacklist, audit fixes for env/curl/kill/sed)

---

## Build

macOS runner / local Mac: `bash scripts/build-ipa.sh` (produces TrollAgent.ipa, installable directly via TrollStore).

CI accepts `RELEASE_VERSION` to auto-inject the release version (fixes version drift); the release artifact ships as `TrollAgent.tipa` (overwrites `latest` on every build).

---

## Related Docs

- [GOALS.md](GOALS.md) — long-term goals and architecture evolution
- [FAQ.md](FAQ.md) — JIT, unified environment, known issues
- [DEV_HANDOVER.md](DEV_HANDOVER.md) — dev handover doc (blockers/fixes/next steps)
- [AGENTS.md](AGENTS.md) / [RULES.md](RULES.md) — AI collaboration conventions
- [HUD_PROGRESS.md](HUD_PROGRESS.md) — HUD development progress
- [VPN_DEVLOG.md](VPN_DEVLOG.md) — VPN capture dev log

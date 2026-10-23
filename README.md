# TrollAgent

**AI-driven iOS experimentation & QA workbench for TrollStore** — Swift + SwiftUI + SwiftPM, runs on iOS 15+ under TrollStore, ships **37 native tools, 100+ subcommands**, all callable by AI through natural language.

> Zero-learning mode: just say it in plain words ("analyze how this app works", "is this plugin safe", "capture this app's traffic") — the AI picks the tools, installs dependencies, does the job, and gives you a one-line human answer.

## Feature overview

### 🧩 Injection & automation (TrollFools-aligned injection strategy)
- `inject` (enable / disable / remove / restore / enable_persisted / status / inspect / list): dylib injection, removal, backup-restore with automatic `.bak_macho` rollback
- `inject verify`: post-injection health check (Mach-O load commands + process liveness + crash detection); `inject static`: Mach-O static analysis
- `inject mem`: in-memory injection (opainject, zero file residue); `hook_apply` / `probe_inspect`; `inject load_dylib`: load your own dylib
- `rescue` (scan / recover_all / cleanup): emergency recovery against "app won't open after injection"
- Failed injections auto-rollback + post-injection launch self-check (auto-restore on crash)

### 📱 App management
- `app` (launch / stop / restart / status / stats): process control (3-tier start fallback: `open -b` → direct exec → url scheme)
- `app diagnose`: auto root-cause for launch failures (injection residue / encryption / signature / crash scene → explicit `next_step`)
- `app install / uninstall / duplicate`: AI install / uninstall / duplicate (silent install via trollstorehelper first)
- `app encrypt_info / decrypt / replace_decrypted / restore_binary`: built-in decryption engine (DecryptEngine: `task_for_pid` + `vm_read` memory dump → rebuilt decrypted image → packaged ipa)
- `app entitlements / deps / cache_inspect / cache_clear / launch_options / inject_package`
- `inject ipa_inspect / dylib_inspect`: IPA/dylib parsing (arch / signature / entitlements / dependencies, telling "parse failed" apart from "genuinely absent")

### 🧹 System cleanup
- Storage ring card + 6 cache categories + quick/advanced cleanup tabs + one-tap cleanup (setuid root full-directory rebuild)

### 📂 Filesystem & data
- `file` (inspect / analyze): file inspection (native metadata; auto-binds `file`+`strings` in the unified environment)
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
- 200+ bilingual bubble lines (time greetings, weather, moods, interactions) that follow the app language setting
- Quick menu to launch WeChat / Douyin / AI chat / hide, resizable, draggable, multi-gesture interactions

## Architecture
- **Registry**: all tools registered in one place in `MCPCore.swift`, fully enabled by default (37 tools)
- **Unified Linux userland**: built-in TrollRuntime (Asbestos interpreter — full Alpine toolchain); the AI can `apk add` any Linux tool (python3/git/sqlite/jq…) and reads iOS files directly via auto-bind (iSH retired)
- **JIT double-ensure**: on launch the app tries ptrace self-attach (silent) + unconditionally invokes the TrollStore URL (`apple-magnifier://enable-jit`, the reliable external-attach path); waits 3s before the first shell command
- **Native iOS tool three channels**: bundled binaries / GitHub Actions cross-compilation / self-written dylibs (`inject load_dylib`)
- **TrollStore mechanics**: bundled setuid root toolchain (ldid/optool/insert_dylib/ct_bypass), silent install via trollstorehelper
- **Failure boundaries**: high-priority tools return unified `error_code/reason/next_step`, no misleading errors
- **i18n**: full Simplified-Chinese / English switching across the whole UI, including the HUD bubble lines and time formats

## Build
macOS runner / local Mac: `bash scripts/build-ipa.sh` (produces TrollAgent.ipa, installable directly via TrollStore).
CI accepts `RELEASE_VERSION` to auto-inject the release version (fixes version drift); the release artifact ships as `TrollAgent.tipa`.

See [FAQ](FAQ.md) for JIT, the unified environment, and known issues.

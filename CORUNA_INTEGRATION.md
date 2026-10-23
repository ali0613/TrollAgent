# Coruna Web Injection Integration (Technical Doc)

## Overview

Integrates the Coruna exploit chain into TrollAgent for one-click dylib injection into any app from a web page. Research/educational use only.

## Exploit Chain Architecture

```
WebView loads the exploit page
    │
    ▼
Stage 1: WebKit RCE (CVE-2024-23222)
    ├─ Path A: iOS OfflineAudioContext heap corruption (Fq2t1Q_dbfd6e84.js)
    ├─ Path B: macOS NaN-Boxing type confusion (YGPUu7_8dbfa3fd.js)
    └─ Path C: macOS JIT structure-check elimination (KRfmo6_166411bd.js)
    │
    ▼
Stage 2: Wasm call_indirect dispatch hijack
    └─ Overwrite JIT function pointers in the Wasm Table → arbitrary native calls
    │
    ▼
Stage 3: PAC bypass (arm64e GOT-Swap)
    └─ Forge PAC signatures via Apple private-framework "confusion proxy"
    │
    ▼
Stage 4: Sandbox escape (mach_vm_allocate RWX)
    └─ Allocate executable pages outside the JIT sandbox
    │
    ▼
Stage 5: JIT Cage escape (PACDB hash forgery)
    └─ Forge rolling hashes in JavaScript to pass the kernel JIT check
    │
    ▼
Stage 6: Shellcode execution (mini dyld)
    └─ Load Mach-O, resolve symbols, apply relocations
    │
    ▼
Stage 7: Kernel exploit (CVE-2023-41974 IOSurfaceRoot)
    └─ IOSurface bug → arbitrary kernel read/write
    │
    ▼
Stage 8: PPL bypass (GPU commands writing physical memory)
    │
    ▼
Stage 9: AMFI patch
    ├─ Enable Developer Mode (developer_mode_status)
    └─ Enable Security Research Mode (allows_security_research)
    │
    ▼
Done: kernel R/W + unsigned execution + arbitrary dylib injection
```

## Integrated Files

### New Swift sources
- `Sources/TrollMCP2/CorunaWebInjector.swift` (14KB)
  - Core manager, singleton
  - Exploit lifecycle state machine
  - Loads the exploit HTML page
  - Handles WKScriptMessageHandler callbacks

- `Sources/TrollMCP2/CorunaInjectView.swift` (16KB)
  - SwiftUI UI
  - Target app picker
  - Dylib file picker
  - Exploit-chain progress visualization
  - Platform path selection

### Modified files
- `Sources/TrollMCP2/SettingsView.swift`
  - Added the "Coruna Web Injection" entry under the Coruna security shield

### Resources (Resources/coruna/)
- `coruna-dump/` (5MB) — full Coruna dump
  - `samples/` — 28 JavaScript modules
    - `Fq2t1Q_dbfd6e84.js` (29KB) — iOS OfflineAudioContext path
    - `YGPUu7_8dbfa3fd.js` (14KB) — macOS NaN-Boxing path
    - `KRfmo6_166411bd.js` (24KB) — macOS JIT path
    - `final_payload_A_*.js` / `final_payload_B_*.js` — final payloads
    - `ios_qeqLdN_*.js` / `ios_uOj89n_*.js` — iOS fallback paths
  - `extracted_binaries/` — extracted binaries
    - `dump.bin` (2MB) — kernel-exploit Mach-O
    - `final_payload_*_shellcode.bin` (31KB each) — ARM64 shellcode
    - `final_payload_*_macho.bin` (89KB each) — Mach-O loader
  - `detailed_reports/` — detailed technical reports
  - `docs/` — full technical analysis docs (6630 lines)
  - `kernel_analysis/` — kernel-exploit reverse analysis

## Device Compatibility

| Item | Device | Support |
|---|---|---|
| Model | iPhone 13 Pro Max (iPhone14,3) | ✅ arm64e (A15) |
| iOS | 16.3 | ✅ within 13.0–17.2.1 |
| TrollStore | installed | ✅ already has kernel-level injection ability |

## Usage Flow

1. Open TrollAgent → Settings → Coruna Web Injection
2. Pick the target app (the one to inject)
3. Pick the dylib file (Documents/dylibs/ directory)
4. Pick the exploit path (auto-detect by default)
5. Tap "Start Web Injection"
6. Watch the exploit-chain progress
7. On completion the dylib is injected into the target app

## Implementation Details

### State machine
```
idle → loadingPage → fingerprinting → webkitRCE → pacBypass 
     → shellcode → kernelExploit → ppLBypass → amfiPatch 
     → ready → injecting → success
                    ↓
                 failed / crashed
```

### WebView communication
- `WKScriptMessageHandler` for Swift ↔ JavaScript bidirectional messaging
- JS side reports progress via `window.webkit.messageHandlers.corunaCallback.postMessage()`
- Swift side parses JSON messages and updates UI state

### Asset loading
- All exploit modules are bundled under `coruna/coruna-dump/samples/` in the app bundle
- Located via `Bundle.main.resourcePath`
- Local exploit pages load via `loadHTMLString` + `baseURL`

## Notes

1. **iOS 15.6**: the Coruna core exploit requires iOS 16.0+; the feature is unavailable on iOS 15.6 (UI shows an incompatibility warning)
2. **No impact on existing features**: fully independent of the existing injection flow
3. **Stability**: the WebContent process may crash mid-exploit; a retry mechanism exists
4. **Research use**: this feature is for security research and learning only

## Build Notes

```bash
# Standard build flow
./scripts/build-ipa.sh

# Assets bundle automatically:
# Resources/coruna/ → TrollAgent.app/coruna/
```

## References

- Google GTIG Coruna report: https://cloud.google.com/blog/topics/threat-intelligence/coruna-powerful-ios-exploit-kit
- matteyeux technical analysis: https://matteyeux.com/posts/2026-03-06-coruna/
- NadSec reverse analysis: https://www.nadsec.online/blog/coruna
- GitHub dump: Rat5ak/CORUNA_IOS-MACOS_FULL_DUMP

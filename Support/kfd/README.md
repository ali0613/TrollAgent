# kfd Jailbreak-Free Trust Injection (system VPN real connect)

> Scope: this is internal research documentation for making TrollAgent's own capture VPN work on the user's own device. kfd is a public open-source kernel-exploit library; the scheme is used only for debugging/development on the user's own hardware.

## Problem Being Solved

TrollAgent installs fine via TrollStore with a fake signature and the main app runs, but the **packet-tunnel extension is blocked by NECP validation** (CS_VALID fails on the fake signature), surfacing as `NEVPNErrorConfigurationInvalid` — the system VPN won't connect and can't be enabled in Settings either.

Auditing the "Fuck toolbox" (a TrollStore-installed .tipa that really connects its capture VPN) confirmed its mechanism:

- **Not** an entitlements matter (no team; allow-vpn is only its signing surface)
- It bundles a **kfd kernel exploit** (`FuckKfdHelper`, `puaf_landa`/MEOW):
  before starting the VPN it writes the packet-tunnel extension's **cdhash into the kernel trust cache** → the system treats the fake signature as trusted → NECP passes → real connect
- kfd is a **jailbreak-free, temporary kernel exploit** (exits after use, leaves no trace), supports **iOS 15.5–16.6.1** (patched from 16.7) — this device's iOS 16.3 is in the golden range
- iOS 17.x needs a **real jailbreak** (Dopamine 3.0 / palera1n), kept alive by `jailbreakd` hooking csops+necp; no solution without jailbreak

## Unified Architecture (one code path across versions)

```
TrollAgent main app (shared layer: chat/MCP/capture/parse)
        │
        ▼  before starting VPN
TrustEnabler.resolvePath()
   ├─ .kfdInject  iOS 16.x no-jailbreak → posix_spawn kfd_helper to inject the trust cache
   ├─ .jailbreak  iOS 17.x jailbroken   → jailbreakd already resident, start directly
   └─ .fallback   neither              → local proxy (127.0.0.1:18180) captures HTTP
        │
        ▼
VpnManager.startVpnViaRegisteredManager()  ← unified exit
```

## Injection Mechanism (since v3.6.18: glue + FuckKfdHelper engine)

Before v3.6.18, `kfd_helper.c` implemented kfd injection itself and got stuck on the `kalloc` (kernel memory allocation) and "call `pmap_image4_trust_caches`" primitives (libkfd only exposes kread/kwrite, no kalloc/kcall).

Since v3.6.18 it reuses a **verified injection engine** (route A):

```
TrustEnabler spawns kfd_helper <VpnTunnel.appex path>
   │  kfd_helper (pure C glue, this repo's tools/kfd_helper.c)
   │    1. parse Mach-O → extract VpnTunnel's 20B cdhash (40 hex chars)
   │    2. posix_spawn Resources/bin/fuck_helper <40hex> from the same directory
   ▼
fuck_helper (= Fuck toolbox's FuckKfdHelper, mechanism fully reverse-engineered)
     kopen(puaf_landa) for temporary kernel read/write
     → patchfind pmap_image4_trust_caches (scans kernel __text signatures at runtime, no static offset table)
     → IOSurface kalloc allocates a kernel-writable memory block (tc_kaddr)
     → kwrite writes the trust cache (containing VpnTunnel's cdhash) into tc_kaddr
     → DMA physical write registration (IOBufferMemoryDescriptor+IODMACommand+ml_dbgwrap_halt_cpu to pause the CPU and bypass PPL)
     → kread verifies the tc took effect
     → kclose exits (jailbreak-free, no trace)
   │
   ▼ returns 0 → TrustEnabler allows → VpnManager starts the packet-tunnel
```

**Why use Fuck's engine instead of building our own**: FuckKfdHelper was verified on iOS 16.3 + TrollStore to really connect and capture; its full mechanism was reverse-confirmed (IOSurface kalloc + DMA physical write bypassing PPL). A self-built port (ObjC/C mix + PPL bypass + halt CPU) is high-effort and can't be locally compiled/verified in a Linux env without Xcode. The Fuck binary lives at `Resources/bin/fuck_helper` (arm64, runs in the TrollStore fake-signature env).

## File List

| File | Purpose |
|---|---|
| `tools/kfd_helper.c` | **Pure C glue** (rewritten v3.6.18): extracts VpnTunnel's cdhash → posix_spawns `fuck_helper` in the same directory, returns its exit code. No libkfd dependency |
| `tools/build_kfd_helper.sh` | macOS build script (pure C + CommonCrypto, no libkfd clone needed) |
| `Resources/bin/fuck_helper` | FuckKfdHelper injection engine (arm64, verified on 16.3) |
| `Sources/TrollMCP2/TrustEnabler.swift` | Swift probe (jailbreak/iOS version/kfd range) + path dispatch + posix_spawn |
| `Sources/TrollMCP2/VpnManager.swift` | `startVpn` calls `TrustEnabler.injectIfNeeded` |
| `.github/workflows/build-trollmcp2.yml` | added "Build kfd_helper" step (non-blocking on failure) |

## Build

The CI macOS runner automatically runs `tools/build_kfd_helper.sh` to put `kfd_helper` (glue) into `Resources/bin/` (packed into the IPA). `fuck_helper` is a **precompiled binary** already sitting in `Resources/bin/`, nothing to build. Locally: `bash tools/build_kfd_helper.sh`.

## Reverse-Engineering Record (FuckKfdHelper mechanism, done)

Full disassembly (30794 instructions) + symbol table of `FuckKfdHelper` from `Fuck.ipa`; the mechanism is fully mapped:

- **kalloc** = `_dg_kalloc` (0x10001f97c): `IOSurfaceCreate` allocates a user-controlled kernel object → kread walks the object chain to locate the kernel address (tc_kaddr)
- **"call pmap"** = `_dma_perform` (0x10001055c): not an ordinary kcall but a **PPL-bypassing DMA physical write** — `IOBufferMemoryDescriptor+IODMACommand` builds a DMA mapping + `ml_dbgwrap_halt_cpu` pauses the CPU → `_dma_writevirt64(pmap_addr, tc)` → `_physwrite64_mapped` → CPU resumes
- **patchfind** = `_find_pmap_image4_trust_caches` (0x100010ab0): scans the kernel `__text` at runtime for prologue signatures (no static offset table)
- Also built in: `_dimentio`/`_tfp0` (tfp0 then kread/kwrite), `_meow`, `_isarm64e`

## Verification (on-device after changes)

1. `bash tools/build_kfd_helper.sh` compiles; `file Resources/bin/kfd_helper` shows arm64; `file Resources/bin/fuck_helper` shows arm64
2. Install TrollAgent → start the VPN → check `/var/mobile/Documents/kfd_helper.log`:
   - expect `extracted cdhash=...`, `invoking .../fuck_helper ...`, `fuck_helper exit=0`
   - FuckKfdHelper's own logs (NSLog/printf) also land in the same file
3. **Hard standard**: Settings→VPN shows "TrollAgent Capture VPN", it can be enabled, and the status bar shows the **key icon** (the in-app "connected" state doesn't count — it can be a false success)
4. If injection fails (log shows kopen failed / fuck_helper exit != 0), confirm the device iOS is 15.5–16.6.1 and not jailbroken

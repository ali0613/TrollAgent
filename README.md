# TrollAgent

**AI 驱动的 iOS 实验与 QA 工作台（TrollStore）** — Swift + SwiftUI + SwiftPM，运行于 iOS 15+ / TrollStore，内置 **37 个原生工具、100+ 子命令**，全部可由 AI 通过自然语言调用。

> 零学习模式：直接用大白话说需求（"分析这个 App 怎么工作的"、"这个插件安全吗"、"抓一下这个 App 的流量"）——AI 自动选工具、装依赖、完成任务，并给你一行人类可读的结论。

---

## 目录

- [项目概述](#项目概述)
- [技术架构](#技术架构)
- [技术类型](#技术类型)
- [项目结构](#项目结构)
- [模块详解](#模块详解)
- [技术集成路线图](#技术集成路线图)
- [构建](#构建)
- [相关文档](#相关文档)

---

## 项目概述

**TrollAgent** 是运行在 TrollStore 生态下的 AI 驱动工作台：把 iOS 上的注入、App 分析、解密、抓包、跨应用 UI 控制、设备伪装等能力，统一封装成一组**可由 AI 自然语言调用的原生工具**，并提供一个始终悬浮在任意 App 之上的 AI 语音伴侣（HUD）。

### 核心能力

| 能力域 | 说明 |
|---|---|
| 工具体系 | 37 个原生工具、100+ 子命令，单一注册中心 |
| 统一执行环境 | 内置 TrollRuntime（统一 Linux 用户态），AI 可 `apk add` 任意 Linux 工具并直接读写 iOS 文件 |
| AI 对话 | 多上游模型（OpenAI 兼容 / Anthropic Messages）、SSE 流式输出、推理强度控制、技能系统 |
| HUD 伴侣 | 独立进程悬浮窗（萝莉/兔娘/猫娘），语音闭环：STT → AI → Edge TTS |
| 远程运维 | 网关 WebSocket 配对、SSH 隧道、内置 HTTP 终端、GitHub Actions 构建与取包 |

### 设计原则

- **零学习模式**：自然语言直达结果，AI 自动选工具与安装依赖
- **失败边界清晰**：高优先级工具返回统一 `error_code / reason / next_step`，不误导
- **可恢复性**：注入失败自动回滚 + 启动自检（崩溃自动恢复）
- **原生化方向**：逐步废除 iSH/Alpine 模拟层，最终目标为 aarch64 Linux ELF 直跑（见 [技术集成路线图](#技术集成路线图)）

---

## 技术架构

```
┌────────────────────────────────────────────────────────────┐
│                    UI 层（SwiftUI）                          │
│  ChatView · SettingsView · BrowserView · GatewayView ·      │
│  CleanupView · FakeDeviceView · ControlCenterView · ...     │
└──────────────────────────┬─────────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────────┐
│                AI 对话内核（OpenAIClient）                    │
│  多上游模型 · SSE 流式 · 推理强度 · 技能系统 · 工具选择合批     │
└──────────────────────────┬─────────────────────────────────┘
                           │ 工具调用（ToolRegistry / MCPCore）
┌──────────────────────────▼─────────────────────────────────┐
│              工具注册中心（37 工具 / 100+ 子命令）             │
│  inject · app · file · db · browser · control · device ·    │
│  web · network · vpn · github · tool.install · ...          │
└───┬──────────┬──────────┬───────────┬──────────────────────┘
    │          │          │           │
┌───▼───┐ ┌───▼───┐ ┌────▼────┐ ┌────▼────┐
│注入引擎 │ │解密引擎│ │ 浏览器  │ │ 控制代理 │
│Inject  │ │Decrypt │ │WKWebView│ │Control- │
│Fools   │ │Engine  │ │+JS 注入 │ │Agent.dylib│
└───┬───┘ └───┬───┘ └────┬────┘ └────┬────┘
    │         │          │           │
┌───▼─────────▼──────────▼───────────▼───────────────────────┐
│               TrollRuntime（统一 Linux 用户态）               │
│  Asbestos 解释器 · Alpine 工具链 · iOS 文件自动绑定           │
│  aarch64 原生二进制三通道：内置 / CI 交叉编译 / 自写 dylib     │
└──────────────────────────┬─────────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────────┐
│              系统底座（TrollStore 机制）                      │
│  setuid root 工具链（ldid/optool/insert_dylib/ct_bypass）   │
│  trollstorehelper 静默安装 · JIT 双保险 · TCC 权限直通       │
└────────────────────────────────────────────────────────────┘
```

- **单一注册中心**：所有工具在 `MCPCore.swift` 一处注册，默认全量启用
- **统一执行环境**：内置 TrollRuntime（Asbestos 解释器，完整 Alpine 工具链）；iSH 已退休
- **JIT 双保险**：启动时 ptrace 自附着（静默）+ 无条件调用 TrollStore URL（`apple-magnifier://enable-jit`）；首个 shell 命令前等待 3s
- **原生工具三通道**：内置二进制 / GitHub Actions 交叉编译 / 自写 dylib（`inject load_dylib`）
- **TrollStore 机制**：内置 setuid root 工具链；trollstorehelper 静默安装；TCC entitlements 直通（麦克风/语音识别不弹窗）
- **HUD 独立进程**：`ch.xxtou.hudapp` 独立二进制内嵌子包，App Group 共享配置，语音闭环全程离线可跑

---

## 技术类型

| 维度 | 内容 |
|---|---|
| 语言 | Swift（主 App / 工具 / AI 内核）、Objective-C++（HUD 悬浮窗）、C（CHev/CISH/CLaunch/CMitm 桥接组件） |
| UI | SwiftUI（iOS 15+），全界面简中/英文双语切换 |
| 平台 | iOS 15+ / TrollStore（越狱亦可用） |
| 依赖管理 | SwiftPM |
| 执行环境 | TrollRuntime 统一 Linux 用户态（Asbestos 解释器 + Alpine 工具链）；路线图目标 aarch64 Linux ELF 直跑 |
| 外部集成 | GitHub Actions（CI 构建）、Edge TTS（语音合成）、多上游 LLM（OpenAI 兼容 / Anthropic） |
| 进程模型 | 主 App + HUD 独立子进程（`NSPrincipalClass=HUDMainApplication`） |
| 注入体系 | TrollFools 对齐策略（dylib 注入/移除/备份回滚）、内存注入（opainject）、ControlAgent.dylib 跨应用控制 |

---

## 项目结构

```
TrollAgent/
├── Sources/TrollMCP2/            # 主工程（136 个 Swift 文件）
│   ├── AppMain.swift             # 入口
│   ├── MCPCore.swift            # 工具注册中心（单一注册表）
│   ├── Models.swift             # AI 对话内核（工具选择/合批/执行循环）
│   ├── OpenAIClient.swift       # 多上游模型客户端（SSE/用量统计）
│   ├── ChatView.swift           # 聊天主界面（模型切换弹窗）
│   ├── SettingsView.swift       # 设置页
│   ├── BrowserManager.swift     # WKWebView + JS 注入浏览器
│   ├── DecryptEngine.swift      # App 解密引擎（内存 dump → 重打包）
│   ├── ControlTools.swift       # 跨应用 UI 控制（ControlAgent）
│   ├── CleanupTools.swift       # 系统清理
│   ├── GatewayClient.swift      # 网关 WebSocket 配对
│   ├── GitHubAccountStore.swift # GitHub Actions 构建/取包
│   ├── AppPickerView.swift      # 应用选择器（搜索/分类/索引）
│   ├── GirlCompanion.swift      # 桌面伴侣角色逻辑
│   └── ...（工具按域拆分：AppTools/FileDbTools/BridgeTools/...）
├── HUD/                         # 悬浮窗伴侣（Objective-C++）
│   ├── sources/HUDRootViewController.mm  # 语音闭环/角色动画
│   ├── HUD/Resources/           # 角色素材（萝莉/兔娘/猫娘）
│   └── supports/entitlements.plist
├── CHev/ CISH/ CLaunch/ CMitm/  # C 桥接组件
├── scripts/                     # 构建脚本（build-ipa.sh 等）
├── Resources/                   # 资源
├── Support/Info.plist           # 版本号（CFBundleShortVersionString）
├── benchmark/ build_out/        # 基准测试 / 构建输出
└── *.md                         # 文档（README/GOALS/DEV_HANDOVER/FAQ...）
```

---

## 模块详解

### 🧩 注入与自动化（TrollFools 对齐策略）
- `inject`（enable / disable / remove / restore / enable_persisted / status / inspect / list）：dylib 注入、移除、备份回滚（自动 `.bak_macho`）
- `inject verify`：注入后健康检查（Mach-O load commands + 进程存活 + 崩溃检测）；`inject static`：Mach-O 静态分析
- `inject mem`：内存注入（opainject，零文件残留）；`hook_apply` / `probe_inspect`；`inject load_dylib`：加载自写 dylib
- `rescue`（scan / recover_all / cleanup）：注入后无法打开的紧急恢复
- 失败注入自动回滚 + 启动自检（崩溃自动恢复）

### 📱 App 管理
- `app`（launch / stop / restart / status / stats）：进程控制（三级启动回退：`open -b` → 直接 exec → url scheme）
- `app diagnose`：启动失败自动归因（注入残留/加密/签名/崩溃场景 → 明确 `next_step`）
- `app install / uninstall / duplicate`：AI 安装/卸载/复制（trollstorehelper 静默安装优先）
- `app encrypt_info / decrypt / replace_decrypted / restore_binary`：内置解密引擎（`task_for_pid` + `vm_read` 内存 dump → 重建解密镜像 → 打包 ipa）
- `app entitlements / deps / cache_inspect / cache_clear / launch_options / inject_package`

### 🧹 系统清理
- 存储环卡 + 6 类缓存 + 快捷/深度清理 Tab + 一键清理（setuid root 全目录重建）

### 📂 文件系统与数据
- `file`（inspect / analyze）：原生元数据；统一环境下自动绑定 `file` + `strings`
- `db`（list / schema / query）：原生 sqlite3 直读 App 数据容器
- `package`（inspect / unpack）：deb/ipa 解包（ar/tar/zip）
- `artifact`（read / write / list）：工作区文件管理
- `container`（refresh / resolve / write / delete）：容器解析与读写

### 🌐 浏览器（WKWebView + JS 注入，Playwright 风格）
- `browser`（status / navigate / screenshot / snapshot / text / click / type / submit / scroll / wait / wait_for）+ 元素绝对 XPath
- `browser form_fields / fill_form`：整表自动填充（React/Vue 兼容 value setter + 事件）
- `browser adblock / clear`：广告/追踪拦截（WKContentRuleList）+ 缓存/Cookie 清理

### 🎮 设备伪装（GreenShield 风格）
- `device fake / restore`：内存 FakeDevice.dylib 伪装 UIDevice 型号（零残留，重启复原）
- `device advertising / idfv`：广告标识 / IDFV；`inject keychain_wipe`：钥匙串清理

### 🛡️ 安全检测
- `device info / probe / snapshot`：TrollStore / task_for_pid / 容器读写 / 注入工具链全项检测

### 🔌 跨应用 UI 控制
- `control`（inject / status / ui_tree / screenshot / tap / swipe / type / key / tap_text / type_text）
- 注入 ControlAgent.dylib → localhost:4789 HTTP API（/status /ui_tree /tap /swipe /type）

### 🏗️ 构建与工程
- `tool.install`：统一工具安装循环（apk→pip→CI；CI 尽力交叉编译原生 iOS 二进制）
- `env.setup_re`：逆向工程工具链一键配置（binutils/file/python3/sqlite/tcpdump/7z…）
- `github`（account_status / trigger_build / fetch_runs / download_artifact）：触发 Actions、监控进度、取包——CI 构建并产出 TrollAgent.tipa
- `project`：工作区项目管理；`macro`（record / run / list / delete / export）：可录制重复操作

### 🤖 AI 与模型
- 多上游模型（OpenAI 兼容 / Anthropic Messages）、SSE 逐字流式输出、推理强度控制
- 工具合批策略：只读/查询类可合批（上限 4 条依次执行），副作用/写类一次一条（双保险拦截）
- 技能系统：`skills.list` / `skills.read` / `skills.set_enabled`

### 📡 网关与自动化
- Gateway WebSocket 配对、多节点调用、`automation`（run / list / jobs / stop / status / history / set_enabled）、`ssh`（exec / scp）、`server`（start / stop / status）
- 内置 HTTP 终端 `127.0.0.1:8790`（/api/tools），浏览器或 SSH 隧道可达

### 📊 网络与诊断
- `web.search`（多引擎回退 Bing→DuckDuckGo→Baidu、并行 queries、来源分级 sort、结果经 save 入知识库）
- `web.fetch`（正文自动抽取，article/main 优先 + 内置浏览器回退）
- `network.capture`（start / stop / requests / analyze）：注入 NetworkTweak 的 NSURLSession 抓包；TLSHook 解密 SSL_read/SSL_write
- `vpn.capture`：系统代理抓包（本地代理 `127.0.0.1:18180`）
- `diagnose`（startup / injection）、崩溃日志解析、`verify`（file / app_running）

### 📚 知识与系统
- `knowledge`（import_text / import_file / search / delete / clear）：知识库 CRUD
- `memory`（search / modify / freeze）、`assistant_memory`（跨会话记忆）
- `location`（get / fake / status / clear）、`reminder`（create / schedule / recurring）

### 🐰 桌面伴侣（HUD）
- 悬浮动漫角色（萝莉/兔娘/猫娘），任意 App 之上：待机帧、趴墙、气泡对话
- 语音闭环：STT → AI → Edge TTS；说话动画切回、坐姿/长按说话姿态素材
- 200+ 双语气泡语录（时间问候/天气/心情/互动），跟随系统语言
- 快捷菜单（微信/抖音/AI 对话/隐藏），可缩放、可拖动、多手势交互

---

## 技术集成路线图

**长期目标**（详见 [GOALS.md](GOALS.md)）：**彻底原生化**——废除 iSH/Alpine 双轨路由，最终实现 aarch64 Linux ELF 直跑，让 AI 只感知一个环境。

| 阶段 | 状态 | 说明 |
|---|---|---|
| P1 统一用户态 | ✅ 已实现 | TrollRuntime（Asbestos 解释器）接管；iSH 模拟层退休 |
| P2 双轨路由收敛 | 🕐 进行中 | 消除 Alpine/iSH 双路由分支，全部工具走统一环境 |
| P3 原生化 | 🎯 目标 | aarch64 Linux ELF 直跑；AI 只感知一个环境（N1 网关局域网穿透调试） |
| 配套 | 持续 | 工具合批提速、HUD 语音闭环、版本化构建发布（7.1.x 自动 bump） |

### 近期里程碑（7.1.x）
- **7.1.88-90**：HUD 语音闭环打磨（趴墙守卫修复、播完回待机、兔娘坐姿素材兜底）
- **7.1.91-97**：UI 细节修复（应用图标填满圆角、设备伪装选择器、模型跳转链路）
- **7.1.98**：用量统计 token 显示（真实 usage 优先）
- **7.1.99-103**：工具合批提速（只读合批上限 4、解释器合批黑名单兜底、审计修复 env/curl/kill/sed）

---

## 构建

macOS runner / 本地 Mac：`bash scripts/build-ipa.sh`（产出 TrollAgent.ipa，TrollStore 直接安装）。

CI 支持 `RELEASE_VERSION` 自动注入发布版本（修复版本漂移）；发布产物为 `TrollAgent.tipa`（每次构建覆盖 `latest`）。

---

## 相关文档

- [GOALS.md](GOALS.md) — 长期目标与架构演进路线
- [FAQ.md](FAQ.md) — JIT、统一环境、已知问题
- [DEV_HANDOVER.md](DEV_HANDOVER.md) — 开发接手文档（卡点/修复/下一步）
- [AGENTS.md](AGENTS.md) / [RULES.md](RULES.md) — AI 协作约定
- [HUD_PROGRESS.md](HUD_PROGRESS.md) — HUD 开发进度
- [VPN_DEVLOG.md](VPN_DEVLOG.md) — VPN 抓包开发日志

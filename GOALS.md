# TrollMCP2 / TrollAgent — 项目目标与路线图（2026-10 版）

> 本文件是项目的唯一权威目标记录。上下文压缩/丢失后，先读本文件恢复方向。
> 最后更新：2026-10-17（14c5 构建中）

## 终极目标（一句话）

**把 TrollMCP2 从"iOS 原生 + iSH/Alpine 双轨 + 路由翻译"收敛为"单一 iOS 原生环境 + Linux 用户态运行时"——iSH 逐步退场，AI 只感知一个环境。**

## 为什么做（用户原话记录的动机）

- "审计后很多工具命令用不了、闪退"——双轨路由 + iSH 模拟器是闪退头号来源（cpu_run_to_interrupt、rootfs 自引用、numpy 段错误全是它）
- "不信任这里面所有工具，总觉得漏洞 bug 很多，环境很不稳，不是一个整体"
- 用户明确要求："去把 a-Shell 拉过来看看，然后看怎么废除 iSH 和路由，全部原生化"

## 已确认的架构决策（带证据，勿轻易推翻）

| 决策 | 依据/证据 |
|---|---|
| **14c1：引擎回退纯 arm64**（已做） | 14ca3ca 双架构把 libish 编入 arm64e，A15 跑 iSH x86 模拟即段错误；6.0.25 纯 arm64 正常 |
| **14c3：Alpine 裁剪**（已做） | 原生已覆盖命令从 Alpine 删除（幂等）；保留 rm/mv/cp/mkdir/chmod/ln/sh/sed/awk/grep/find/head/tail（apk 脚本依赖） |
| **默认删 iSH，仅"特定工具确实需要内核"才按需保留**（用户拍板） | 真 Linux 内核语义对 AI/用户实际使用频率 <1%；删 iSH = 根治闪退 + 包小 ~15MB |
| **ELF 不用"格式转换"，用"运行时翻译"** | ELF→Mach-O 转换不可行（dyld/libc/syscall 全不对应）；正确姿势 = ELF 加载器 + 指令直跑 + syscall 翻译层（WSL1/elfuse 架构） |
| **"装工具"换入口**：pip 即时装 / 下载 arm64 二进制 / CI 重编进包，apk 非必需 | apk 装的是 Linux ELF，原生跑不了；但有源码就重编（99% 工具），无源码走 ELF 运行时 |
| **环境变量不"装"要"统一"** | 现在双轨（Alpine Linux PATH / 原生进程环境）不一致；原生化后统一 PATH(bin/)/HOME/TMPDIR，AI 无感 |

## 分层愿景（终态）

```
App 原生系统（AI 全走这里，零感知）
 ├─ 原生命令 36+（Swift）+ bin/ 原生工具（lua/node/jq/r2/cstool/tree/xz/which/llvm 族）
 ├─ CI 重编 Mach-O 扩军（P1）+ 原生 pip（Python 生态）
 ├─ WASM 转译（可选，依赖重无 fork 的工具兜底）
 └─ aarch64 Linux ELF 运行时（P5 终极：ELF 直跑 + syscall 翻译 = "一个环境的 Linux 真系统"）
      —— iSH 的 syscall 翻译层现成可复用，本质是"iSH 去掉 x86 模拟器换 aarch64 直跑"
保留后备：iSH/QEMU 类仅作"需要真内核行为"（raw socket/ptrace）的显式应急
```

## 路线图状态

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | 14c1 引擎回退纯 arm64，Alpine 恢复 | ✅ 已交付装机（Alpine sh 实测恢复） |
| P1 | 原生工具扩军——**只做 iOS 语义对等类**（tree/xz/which ✅、file/zip 🔧14c6、diff/curl/wget 按需）；**不做 busybox 原生版** | 🔧 进行中 |
| P3 | 原生 pip + CI 编译进包（"装包=更新"） | ⏳ 部分（pip 原生 Python 已内置） |
| P4 | 路由废除 + Alpine rootfs 不打包 + 统一环境层 | ⏳ 14c3 裁剪已做，rootfs 移除未做 |
| P5 | aarch64 ELF 运行时（复用 iSH 翻译层 + 新加载器）→ **首个验收目标 = busybox ELF 直跑（100+ Linux 工具白送）** | ⏳ 远期，参考 elfuse 设计 |
| ~~P2~~ | ~~原生受限 shell（组合命令原生化）~~ **已并入 P5** | 2026-10-17 用户拍板"组合命令最后弄"：组合命令终极形态=P5 ELF 运行时（Linux shell 语义白送），自写 Swift shell 无必要；且 fork 实测在原生 iOS 挂起（python3 subprocess NO JSON），P2 的进程拉起路线本就要等 P5 |

**关键决策（2026-10-17 用户确认"busybox直接弄"后推演出）**：busybox **不交叉编译成 Mach-O**——①编译要大量 patch（Linux 头缺失）②运行时是假 Linux 语义（ps/mount/sh 失真，fork 受限）③P5 做完即淘汰。正确姿势：**busybox 作为 P5 的首个验收对象**（静态单二进制 100+ 工具 = ELF 加载器+syscall 翻译层完整测试集），P1 只做 iOS 语义天然对等的工具。

## 当前进行中（2026-10-17）

- **14c5 已交付装机并真机验证通过**（build a0d8224）：tree/xz/which/chmod 原生直跑、Alpine 裁剪生效（ls 已删/sed 保留）、全程零崩溃
- **下一步：P1 剩余扩军——busybox 全家桶**（TrollStore 生态现成 iOS arm64 busybox 预编译，一次覆盖 100+ 工具：tar/cat/ls/cp/mv/rm/head/tail/sort/uniq/date/dd/df/du/stat/wc/seq/printf…）+ file（libmagic）/zip/diff
- 已记录事实：python3 subprocess/os.system 在原生 iOS 下挂起无响应（fork 受限再证实）→ 组合命令并入 P5，不再自写 Swift shell

## 仓库与发布信息

- 仓库：zrrt/trollmcp2（main），GitHub token 存会话记忆/环境变量（勿写入本文件——Push Protection 拦截）
- 发布：release latest = TrollAgent.tipa（每次构建覆盖）
- 真机远程测试：N1 SSH 跳板 root@121.31.139.125 / 密码 1335612901 → iPhone 终端 192.168.31.108:8790（/health 免认证查 build）
- a-Shell 结论：主 App 源码未公开；a-Shell-commands 是 WASM 命令（非 iOS 原生 ARM 二进制），可作工具清单参考

---

## VPN/抓包主线交接留档（2026-10-19 归档）

### 背景
- 用户上传《巨魔Fuck法克工具箱_1.8.5.tipa》（TrollStore 生态抓包工具），目标是让 TrollAgent 具备同等 VPN 抓包能力，解决"点注入信任就黑屏"问题。
- **最终定案：放弃 kfd 注入路线，改走 VpnTunnel 自带 entitlements 直接起隧道。** 本主线已整体交接另一 AI，不再由本会话推进。

### Fuck 工具箱原理（分析结论）
1. Fuck 是**注入型抓包工具**：`fuck_helper`（信任自己的黑盒 helper）通过 **kfd（kernel read/write 漏洞）** 注入抓包代理到目标 App 进程。
2. VPN 隧道：NetworkExtension `NEPacketTunnelProvider` 起 utun；HTTPS 解密靠 **mitm 证书**（系统装 mitm CA）。
3. **黑屏根因（已钉死）**："点注入信任就黑屏" = kfd 注入目标不匹配 → **DMA panic → 黑屏重启**。`fuck_helper` 只信任自己，无法对 VpnTunnel 定向信任；每次开 VPN 触发注入 → 不匹配 → panic。
4. Fuck 的抓包 VPN 用户侧可用：隧道+证书正常，崩的只是注入 hook 步。→ 取舍：**隧道保留、注入砍掉**。

### 已放弃路线（死路，勿重试）
**核心放弃：kfd 注入**（注入信任 → DMA panic 黑屏），连带整套注入 hook 路线。iOS 16.3 / iPhone14,3 / TrollStore 6.0.25 实测锁死清单：
| 路线 | 实测结果 |
|---|---|
| kfd 注入（fuck 同款） | 目标不匹配 → DMA panic 黑屏 |
| MAP_JIT（含 16KB 对齐/MAP_FIXED） | 全部 EINVAL |
| ptrace 自 attach | EPERM |
| fork 子进程 | iOS16 必 SIGBUS |
| dlopen 固定 LaunchServices 路径 | iOS16 无实体文件 |
| apple-magnifier://enable-jit 切 TrollStore | LSOpen err=0 仍 EINVAL，闪切闪退 |
| allow-jit entitlement | 已签但 AMFI 不认（csops allow-jit-check=0） |
| RWX mmap | 成功但取指 SIGBUS，**csflags=0x32007005 铁证** |

### 新方向：VpnTunnel 直接起隧道（自研 vs 复刻判断）
- **判断：借鉴概念 + 自研实现，非照搬源码**（tipa 是二进制，无源码，只能反汇编参考机制）。
- 新方案 = NEPacketTunnelProvider 子类 + 系统 VPN 配置 + TrollStore 签名 entitlements（no-sandbox / platform-application / networkextension packet-tunnel-provider）；开 VPN 不再触发 kfd 注入，纯系统 VPN 路由抓包。
- **代价**：放弃注入 = 放弃定向 hook 目标 App，只能抓 VPN 路由到的流量。
- **复刻 Fuck 最小清单**：①NEPacketTunnelProvider 子类起 utun 读写隧道包；②NETunnelProviderProtocol + NEVPNManager 装配置（显示名自定义，苹果设置里显示我们起的名字）；③entitlements（networkextension packet-tunnel-provider + no-sandbox/platform-application）；④mitm 证书安装（抓 HTTPS 必需）；⑤无需 helper、无需 kfd。
- 参考 Fuck 二进制手段：`ldid -e` 看 entitlements、反汇编（capstone/Hopper）看隧道启动与包处理、`strings` 找 VPN 配置/证书文件名。

### 项目硬事实（供新 AI 继续）
- 仓库：github.com/zrrt/trollmcp2；本地 checkout `/home/user/Doubao/chats/38444602897901314/trollmcp2_audit`
- 可用 PAT 存会话记忆/环境变量（勿写入本文件——Push Protection 拦截）；已失效 PAT 列表存会话记忆
- 公网跳板 IP（当前）：`121.31.136.34`（旧 121.31.141.66 / 121.31.139.125 已超时；IP 变了必须问用户要新）；SSH root / 密码 `1335612901`
- iPhone 远程终端：`http://192.168.31.108:8790` token `1335612901`；API `POST /api/tool` body `{"name":"shell.exec","params":{"command":"…","runtime":"ios"}}`（经跳板 sftp 写 /tmp/body.json 再 curl）
- 设备端：bundle `org.python.python`；App `TrollAgent.app`；真机 busybox `/var/mobile/Documents/Workspace/linux/busybox`；日志 `elf_out.log`；崩溃 `crash/sig_*.txt`
- 用户习惯：每个构建走 commit → CI → release asset+aka → 手动 TrollStore 安装 → 真机验证；留档走 commit 历史 + GOALS.md；不绕路反复试死路。

### 当前主线状态（elf-runner，顺带留档）
- 目标：elf-runner（arm64 静态 PIE ELF 加载器 + syscall 翻译 + CELF 解释器，编进 TrollAgent）跑通 aarch64 静态 PIE busybox → **iSH 逐步退场**。
- iOS16 W^X/AMFI 锁死一切可执行内存 → **解释器路线 A 定案**（逐指令模拟 arm64，指令当数据处理）。
- 离线调试现状（Linux harness `busybox-test/test_emu.c` + `CELF/emu.c`）：
  - 已修复：寄存器 ADD/SUB extended 形式（envp 计算）、NEON、LDP/STP 寻址、auxv 栈布局。
  - 当前崩溃点：**musl 静态自举内嵌 RELOC 循环区 0xf4dd0 `str x0,[x21,x22]`**；0xf4d8c 从 ldso 结构读出的 reloc 边界槽位全零/垃圾（[0x13da08]=0、[0x13da10]=栈顶值），根因未钉死；最大嫌疑 = harness 预应用 1379 条 R_AARCH64_RELATIVE 与 musl 内嵌循环**双重加基址**，或节地址/vaddr 布局理解有误。
  - 本地改动（CELF/emu.c 新增、CELF/elf-runner.c、ShellTool.swift）未 push、未走 CI→release→真机流程。

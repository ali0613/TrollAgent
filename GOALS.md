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

---

## elf-runner 离线调试进展（2026-10-19 晚，Linux VM /tmp/test_emu + CELF/emu.c）

### 已修复（有实证）
1. **保存槽归零根因（本段重大突破）**：`busybox-test/test_emu.c` 的 `translate_syscall` stub 里 `newfstatat`（case 79）`memset(st,0,144)` 越界——aarch64 `struct stat` 实为 128B，144B 覆盖了 0xffbc 帧的 x19 保存槽（0x...2bc0）→ 0x1008c `ldp x19,x20,[sp],#0x1f0` 恢复出 0 → 崩溃 `mem fault addr=0x370`。**修：memset 缩到 64B。修复后启动路径完全穿通（不再 SIGSEGV）**，一路到 `exit_group(127)`。
   - 定位过程：stp after=非0 / ldp v1=0 / ptr1（直接指针读）=0 三重矛盾 → WST 全区间+g_slot 无覆盖写 → grep emu.c 无绕过 mem_st 的直接写 → 最终锁定 stub 的 syscall 模拟写用户内存（绕过 emu 层，WST 天然抓不到）。
2. 此前 9 个 bug（TBZ 掩码/逻辑立即数/aarch64 syscall 编号/NEON MOVI 等）仍在。

### 当前活跃问题（未定论）
- **argv 正确但 applet not found**：guest 初始栈验证 `argc=3 argv=[bp2/busybox,echo,hello]` 完全正确（BP 0xfc3c 从 x0=slot 读）；musl __dls2 入口（br x16 → GOT[0]=0xfc0c）收到的 stack_end=x1=slot 且 `[slot]` argc/argv 正确（BP 0xfd00 打印）。但 busybox 报 `codex EXPERIENCE_BUNDLE_MANIFEST_SHA256=...: applet not found`（applet 名被读成宿主环境字符串）——musl 栈重构（0xfc3c-0xfd00，E.sp 曾下移 0x200 后恢复）或 __libc_start_main 传参链路中 argv 被污染，**下一步在 musl 调 main（0x10910 bl 0x1098c 前的 basename 处理）处继续断**。
- **0x10914 崩溃模式（x1=0x2f）**：BP 模式下反复 `mem fault addr=0x2f`（pc=0x10914 附近、x1='/'、x19=base+0x13d000）。0x10910 `bl 0x1098c`（basename 处理）前 x1 被设为字符 '/'，0x1098c 内疑似把 x1 当地址 `ldrb`（emu 解码错或调用约定错）。需 dump 0x1098c 内指令核对。
- **TRACE 模式与 BP 模式路径不一致**：TRACE 模式在 0x103dc 遇 unsupported（CSEL 0x1ac10e81），BP 模式不遇——两模式执行到不同点（疑似 TRACE 慢速改变后续分支时序或路径本身多态），需统一调试环境。

### 调试开关（emu.c，环境变量）
- `EMU_LDP=1`（ldp 恢复打点 + ptr1 直接指针读）、`EMU_BP=1`（断点列表含 0xfc04/0xfc08/0xfc3c/0xfd00/0xf4d90/0xf4d00/0xf4d04/0xf4cf0/0xf4e18/0x10914/0xffbc/0x10078/0x1008c 等，打印关键 reg + argv0/start/brx16/stack0/main-10914 打点）、`EMU_WST=1`（写追踪）、`EMU_TRACE=1`。
- 重跑：`cd busybox-test && gcc -O2 -o /tmp/test_emu test_emu.c ../trollmcp2_audit/CELF/emu.c && EMU_BP=1 timeout 30 /tmp/test_emu bp2/busybox echo hello`（/tmp 会清，test_emu 需重编译）。

### 下一步（续接指针）
1. dump 0x1098c 区指令，核对 0x10910 bl 前的 x0/x1 约定（busybox basename 处理）与 emu 解码。
2. 定位 musl __libc_start_main 调 main 的 bl（BP 0xf4d90 附近已进入 musl 启动区），打印 main 实参（argc/argv）。
3. 修 CSEL（0x1A 系条件选择）以统一 TRACE/BP 路径。
4. 跑通 `echo hello`（exit 0）后：走 commit→CI→release+aka→真机 TrollStore 装→`elf-runner busybox echo hello` 验证；再实施 busybox 内置进包/首次打开自动拉取。

### 构建/交付现状
- CELF/emu.c、CELF/elf-runner.c、Sources/TrollMCP2/ShellTool.swift、busybox-test/test_emu.c：**本地改动，未 push**（含本段 stub 修复与 BP 打点）。
- 跳板公网 IP：`121.31.136.34`（2026-10-19）；root 密码 `1335612901`；真机远程终端 `http://192.168.31.108:8790` token `1335612901`。

---

## elf-runner 离线调试进展（2026-10-20 凌晨续：指令覆盖补齐 + 新卡点）

### 本段补齐的指令族（emu.c，全部本地未 push）
1. **CSEL/CSINC/CSINV/CSNEG**：掩码 `0xFFE00000 == 0x1A800000/0x5A800000/0x9A800000/0xDA800000`（W/X × base/inv 四系），op（bit22-21）+op2（bit11-10）区分语义。**教训：早期 0x7F800000 掩码误吃 SDIV（0x1AC10E81 实为 sdiv，capstone 验证）**。
2. **SDIV/UDIV + LSLV/LSRV/ASRV/RORV**：统一 `0xFFE00000 == 0x1AC00000/0x9AC00000`；**bit13=1→variable shift（op2 00/01/10/11），bit13=0→div（op2=11 为 SDIV，其余 UDIV）**。编码表经 capstone 逐一反查（0x1AC32800=asr、0x1AC30800=udiv、0x1AC32000=lsl、0x1AC32C00=ror、0x1AC30C00=sdiv）。
3. **RBIT/CLZ 拆分**：`0x5AC00000`（RBIT）/`0x5AC01000`（CLZ）W，`0xDAC00000`/`0xDAC01000` X；**教训：0xFFE00000 粗掩码把 CLZ（0x5AC01000）当 RBIT 执行 → 0xdd578 类别查表返回 0x3fd 越界（cls-ret 实测 0x3fd→修后 0x1d）**。
4. **BFM/BFI/BFXIL**：`0x33000000`（W）/`0xB3000000`（X）；imms>=immr→BFI 插入，否则 BFXIL 提取。
5. **LDUR/STUR（unscaled imm9）**：opt(bit11-10)==0/2 且 bit21=0 → 带符号 imm9；**教训：之前归入 reg offset 的 unprivileged 拒绝（UNSUPPORTED 0xf85f8087=ldur x7,[x4,#-8]）**。
6. **stub syscall 补 135/144/146**（sched/rt_sig 系，返回 0）。

### 当前状态（2026-10-20）
- **指令解码全通**：TRACE/BP 模式均不再 UNSUPPORTED insn；启动路径从"stub 越界 SIGSEGV"推进到 **busybox main 的 argv/basename 处理**（BP 0x10914 实测 x0="busybox" applet 名正确，x19=base+0x13d000 正确）。
- **新卡点 1（BP 模式崩溃）**：pc-off≈0x31468，`x0=0x7600000000000000`（"v" 开头无效指针）、x1=模块内 0x...1b04、x2/x19/x20=0x1110、x21=0x3e8(1000)、x30=0x31484。上下文：0x31464 `tbz w0,#0` → 0x31468 adrp → 0x3146c add（x0=base+0x10fd9e "got UDP packet"）→ 0x31470 bl 0x112c4（printf("%s", x1) 系，0x11250 为 printf 展开）。**busybox echo 却走到 udhcpc 的 "got UDP packet"——执行流错乱（applet 分发/跳转错）或 printf 参数污染**；0x11250 内 str q 大量压栈（0x3d80 系 SIMD 已支持）。
- **新卡点 2（applet not found）**：TRACE 模式曾走到 exit_group(127)（applet not found，applet 名读成宿主 env 串）；0xfd00 实测 argc/argv 正确，污染点在 musl 栈重构（0xfc3c-0xfd00）或 __libc_start_main 传参链路，**未定位**。
- TRACE/BP 两模式路径不一致（TRACE 曾 exit 127、BP 崩 0x31468）：疑似某处读宿主环境/未初始化值导致分支不同。

### 下一步（续接指针）
1. BP/TRACE 对比 0x31468 崩溃链：打印 0x31460（[sp+0x98]）与 0x31474 strb 的 x22/w25；或先修 "applet not found"（定位 musl 传参污染）——二者可能同源（执行流错乱）。
2. 补 printf（0x11250）内部缺失指令（若 UNSUPPORTED 再现）。
3. 跑通 echo hello（exit 0）→ commit→CI→release+aka→真机 TrollStore 装→elf-runner busybox echo hello 验证。

### 续：0xDD468 定位（2026-10-20 凌晨二段）
- **BP 实证**：0xffbc（applet 查找）x0="busybox"（applet 名正确）；0x10914 x0=basename 结果 "busybox" 正确——**applet 名链路无污染**。
- **fault 实际在 0xDD468**（非 0x31468，此前 base 推算误）：`ldrh w0, [x1, x0, lsl#1]`，x1=base+0xFFB04（映射内，adrp #0xff000+0xb04 正确）、索引 x0=fault 时=0x7600000000000000（异常）。上下文 0xdd43c-0xdd474 = musl malloc 系函数（tst #0x1f / and #-0x1000 / ubfx x0,#6,#6 → ldrh 查表 / ubfiz <<4）。**"got UDP packet"（0x31464 区）与 0xDD468 是不同地点**：执行流先到 udhcpc debug 打印、后续 malloc 内 fault。
- **疑点**：0xdd45c `ubfx x0,x0,#6,#6`（0xd3462c00，imms=11 immr=6，UBFX lsb=6 width=6）输出应为 0（0x7600... 位 6-11=0），fault 时 x0 却=0x7600...——**UBFM 分支对 imms>=immr 的特例语义需复核（UBFIZ vs UBFX）**；或 E.pc 打印滞后（fault 在 ldrh 之后某处）。
- **未决**：applet 分发为何走到 udhcpc（0x31464 debug 打印触发，[x0+0x1e8] bit0=1，x0=[sp+0x98] 来自 main 之后）；TRACE/BP 路径差异。

### 续：UBFM 根因修复 + echo 跑通（2026-10-20 三段）
- **0xDD468 fault 根因**：emu UBFM 分支把 UBFX/UBFIZ 误当 LSL（v<<(63-imms)）→ 0xd3462c00（ubfx x0,x0,#6,#6，imms=11 immr=6）输出 0x7600000000000000（118<<52）→ ldrh 索引爆炸。**修复：imms==full→LSR；imms>=immr→UBFX（(v>>immr)&mask(imms-immr+1)）；else→UBFIZ（(v&mask(imms+1))<<(w-immr)）**。
- **SIMD LDP q 掩码补 0xAC400000/0xAD400000**（0xad4187e0=ldp q0,q1,[sp,#0x30] 曾漏匹配）。
- **stub syscall 198**（容错返回 0）。
- **突破：echo 已执行并输出**（exit_group(1)，从 exit 127/applet not found 推进）：
  - stdout 实测 = `echo^@^@^@^@^@^@: `（"echo"+6 NUL+": "）——**echo_main 收到的 argv[1] 被污染成 "echo\0..."（应为 "hello"）**，echo 打印 argv[1]+": "。
  - 污染点在 busybox main 的 applet 分发链（0x1091c ldr [x19+0x370] → 0x10924 bl 0x10538 附近；BP 0x10928 未触发，路径在 0x10538 内部）。
- **下一步**：BP 0x10538 入口/内部定位 argv 污染（x0=applet 名、x1=argv[0]、"echo" 从何写入 argv 区）；修好后应输出 "hello"、exit 0。

### 续：argv 分发点实证正确（2026-10-20 四段）
- BP 0x1091c/0x10924/0x10538：**argv 在 applet 查找入口完全正确**（argv0='bp2/busybox' argv1='echo' argv2='hello'，x0="busybox"）。[x19+0x370]（base+0x13d370）存 applet 名指针正确。
- 0x10928（bl 0x10538 返回点）BP 始终不触发——0x10538 返回路径异常（待查，可能 0x10538 内部 ret 逻辑或 bl 目标差异）。
- **echo 污染（"echo\0..."）发生在 0x10538 之后到 echo_main 之间**（argv 进入 0x10538 时正确）。候选：0x10538 内部写 argv/全局、或 main 在调 echo_main 时重排参数。
- **已闭环**：UBFM/SIMD/syscall198 全部修复入 main（5cc88df）；echo 执行+输出+exit（内容/退出码待修）。

### 续：BP 干扰实证 + 系统根因方向（2026-10-20 五段）
- **BP 打点改变 guest 路径**（加 0x1091c/0x10924/0x10538 打点后 echo 输出消失、rc=0；去打点后 echo 输出 "echo\0...: "、exit 1）——**guest 读未初始化内存，值依赖宿主 fprintf 副作用**。
- **系统根因候选**：test_emu 初始栈布局（slot[2+narg]=0 envp 空、aux 表 AT_PHNUM=6、AT_RANDOM 指向 rand16、无 AT_NULL 之外填充）——musl 启动读 auxv/envp 处存在未初始化/布局差异 → 分支不稳定。**下一步应重构初始栈（完整 envp/auxv/清零）而非继续逐点 BP**。
- **已闭环**：UBFM/SIMD LDP q/syscall198/argv 分发实证（2142dba）；echo 执行链打通（输出+exit）。

## 2026-10-20 突破：SXTW/SXTX 移位缺失 → echo 完全跑通

**根因（最后一块拼图）**：emu.c LDR/STR 寄存器偏移解码中，SXTW（option=110）/SXTX（option=111）漏了 `<<(sh?sz:0)` 移位。
busybox main 的 applet 表查询 `ldr x2, [x1, w20, sxtw #3]`（0x10520）地址算成 x1+72（未×8），
读到错误表项 0x2fdac（网络 applet）而非 echo_main 0xabaf0 → blr 到错函数 → 该函数 bb_error_msg
打印 "echo: "（applet 名前缀）→ exit 1。此即此前所有"argv 污染/echo: 输出"的最终根因。

**修复**：
```c
case 6: off = (uint64_t)(int64_t)(int32_t)(uint32_t)rmv << (sh ? sz : 0); break; /* SXTW #sh */
case 7: off = (uint64_t)(int64_t)rmv << (sh ? sz : 0); break;                    /* SXTX #sh */
```

**修复后实测（busybox-test/test_emu）**：
- `echo hello` → stdout "hello"（fd=1 write n=6），echo_main argc=2 argv0='echo' argv1='hello' 正确
- `echo hello world` → "hello world"
- `echo -n hi` → "hi"（无换行）
- `true` → rc=0
- `busybox`（无参数）→ "BusyBox v1.36.1 multi-call binary." usage 输出
- 退出码遗留问题：echo 正常路径 rc=218（exit 读 [0x13d330] 全局返回码=218，0x1052c strb 写 [argv+0x330] 疑似地址/寄存器 x1 与 exit 读址不一致，待查）

**栈重构（前段）**：字符串区移至 sp_top-512（musl 启动清零 sp 上方 0x200B），指针表区 sp_top-4096，
完整 auxv（AT_PHDR/PHENT/PHNUM/PAGESZ/BASE/FLAGS/ENTRY/UID/EUID/GID/EGID/CLKTCK/SECURE/RANDOM/HWCAP=0/EXECFN/PLATFORM/HWCAP2/NULL）。

**打点工具**：EMU_DBG 开关（不干扰路径的纯数值打点）0x10928/applet 表 0x10520（funcoff）/0x10528（blr 目标）/echo_main 入口；
svc write 打点含 fd/pc-off/lr-off/n/hex；验证 blr 目标=0xabaf0（表项）后确认修复生效。

**状态**：echo 全系列跑通；下一步查 exit code 218（0x1052c strb 与 0x113b8 ldrb 地址不一致），
之后 commit→CI→release+aka→真机验证。

## 2026-10-20 续：exit code 218 调查（遗留）
- 澄清：0x1052c 实际为 `adrp x1, #0x13d000` 重设基址，exit_code 存储逻辑正确（strb w0→[0x13d330]）。
- echo svc 序列全 trace：135/144/146/214/222/64 均有 stub 且无 -ENOSYS 返回 → 218 不是 -ENOSYS 截断。
- rc=218 稳定；EMU_DBG 打点（fprintf 副作用）会使路径漂移到 -38（unsupported）→ 无 BP 结果可信。
- 218 = echo_main 返回值（0x10530 strb 到 [0x13d330] 后 exit_group(218)）；echo_main 内部某处返回 218（应 0），
  机制未明，留待真机/进一步 dump echo_main 尾部（0xabd00 后）。影响 `$?`，不影响输出。

## 2026-10-20 突破2：真机崩根因 = CELF interpreter 栈 auxv 错位（已修复）
- 真机 `elf-runner busybox echo hello`：musl reloc 循环 mem fault @0xfd64（x0=0 x1=0x218 far=0x220）→ -14。
- 定位：真机 busybox SHA1=2be6362d… 与 bp2 完全一致（同文件），差异在 CELF/elf-runner.c 的 interpreter 栈构建。
- **根因**：`aux = slot + 2 + narg` 使 auxv 起点覆盖 slot[2+narg]（envp NULL）→ musl 把 auxv 前几项当 envp
  遍历（非 NULL 不终止）→ auxv 整体错位 → AT_PHDR 丢失 → _start 的 DYNAMIC/rela 计算全错 → x0=0，
  rela 表指针=0x218 → ldr [x1+8] 读 0x220 mem fault。
- **修复**：`aux = slot + 3 + narg`（跳过 envp NULL）+ 补齐 AT_CLKTCK/AT_HWCAP/AT_HWCAP2/AT_PLATFORM
  （对齐离线 test_emu 跑通配置）。
- **本地复现验证**：test_emu 临时改 aux 为 &sp[a-1]（模拟错位）→ 崩溃输出与真机逐字节一致
  （x0=0x0 x1=0x218 x2=0x8148 mem fault @0xfd64）；恢复后 echo hello 正常。

## 2026-10-20 突破3：真机第二崩 0xbd30（x19 垃圾）= 调试打点漂移 + syscall stub 缺失（已修复）
- 真机 auxv 修复版：过了 reloc（1379 RELATIVE），interpreter entry 正常，推进到 0xbd28-0xbd30 崩
  （x19=0x283ce1e5e 垃圾指针，mem fault far=0x0），崩溃前有 [dbg] LDP/STP 打点风暴 + unsupported 96/73。
- **分析**：emu.c 有 2 处无条件打点（LDP/STP branch + stp x19/after 跟踪，每个 LDP/STP 都 fprintf）→
  大量 fprintf 副作用漂移 guest 路径（离线已证）；真机 elf-runner translate_syscall 缺 96(getrlimit)/73/135/144/146/214/198 → -ENOSYS。
- **修复**：① 全部调试打点门控到 EMU_DBG/EMU_LDP（默认关，本地验证 dbg 行=0）；② 补 syscall stub 96/73/135/144/146/214/198 返回 0。
- 本地无打点干净路径：echo hello 正常输出，0 [dbg] 行。退出码 218（-38）为独立遗留
  （退出路径遇 UNSUPPORTED madd 0x1b027c82，后续补解码）。

## 2026-10-20 突破4：真机无崩溃点！停在 UNSUPPORTED madd → 补 32 位 MADD/MSUB
- 干净路径版真机：**无 mem fault**，执行 20710 步，停在 UNSUPPORTED insn 0x1b004c42（32 位 madd）。
  证实此前 x19 垃圾 = 打点漂移，auxv+打点门控+syscall stub 后主路径全通。
- 修复：emu.c MADD/MSUB 分支加 0x1B000000 掩码（32 位 madd/msub；sf 由 bit31 自然给出，0x9B=64 位 0x1B=32 位）。
- 本地验证：echo hello 输出 ✓，之后退出路径有新 mem fault（x1=-16，exit code 问题，独立遗留）。

## 2026-10-20 突破5：真机输出 "echo: "（错误 applet）= CELF 栈布局未对齐 test_emu
- 真机 madd 修复版：无崩溃、无 UNSUPPORTED，但输出 `echo\0\0\0\0: `（bb_error_msg 错误路径，本地同代码是 hello）。
- **根因**：CELF/elf-runner.c 的初始栈与本地跑通配置 test_emu 不一致：
  ① argv 字符串用宿主指针（真机进程 argv）而非复制到 guest 栈；
  ② 指针表在 sp_top-512（test_emu 在 sp_top-4096）；
  ③ auxv 键值错（CLKTCK=11 应为 17、HWCAP=15 应为 16、PLATFORM=29 应为 15、缺 UID/EUID/GID/EGID）；
  ④ 栈 1MB（test_emu 32MB）。
- **修复**：CELF 栈构建整体对齐 test_emu（字符串复制 guest 栈、指针表 -4096、标准 auxv 键值、32MB 栈）。

## 2026-10-20 突破6：布局迭代（真机反馈驱动）
- v2（guest 字符串 + 指针表 sp_top-4096 + 标准键 + 32MB）真机崩回 reloc 0xfd64（x1=0x218）：
  sp_top-4096 与 musl 启动清零区冲突 → auxv 读取错位。
- v3（当前）：指针表回退 sp_top-512（真机已验证过 reloc 的位置）+ 字符串复制到 guest 栈但放指针表下方
  sp_top-8192（远离清零区，避免宿主指针导致的错误 applet "echo: "）+ 标准 auxv 键。

## 2026-10-20 突破7：布局 v4（本地复现定案）
- 本地 v3 布局（指针表 -512）复现 `applet not found`（127）→ 指针表 -512 错误方向。
- 真机 v2 崩 reloc 的根因：auxv 写入用 aux[a++]（a 初始 = narg+3）→ 写到 slot 之外错位（本地 v1 用 aux[aa++] 从 0 起）。
- **v4（当前）= 完整复制本地 v1 跑通配置**：指针表 sp_top-4096、字符串 guest(sp_top-512)、标准 auxv 键、
  auxv 从 0 索引写入、32MB 栈。本地 v1 已输出 hello。

## 2026-10-20 真机 v4 结果（重要转折）
- v4（=本地跑通配置逐字节复制）真机仍输出 `echo\0e '%s: `（与 v3 相同）→ **非布局问题**。
- 本地同一布局 hello ✓，真机 applet 查询总错 → **真机环境特有差异**（emu 在 iOS 进程 vs Linux 进程，
  或 musl 启动路径差异）。宿主字符串版(v1)输出 "echo: "、guest 字符串版(v3/v4)输出 "echo\0e '%s: "。
- **下一步诊断（真机 trace）**：开 EMU_DBG 一次性打点（0x10520 打印 w20/表项），或用 API env 传 EMU_DBG=1；
  关注 find_applet 返回值与 0x10520 SXTW 查询是否与本地一致。若 EMU_DBG 漂移，改加"一次性"诊断
  （首次命中后自关）。

## 2026-10-20 诊断进展：真机 applet 查询正确（w20=72 funcoff=0xabaf0）→ 问题在 echo_main 内部
- 真机一次性诊断：`[diag] 10520 w20=72 funcoff=0xabaf0 argvp=...` —— 与本地完全一致！
  **applet 查询正确，echo_main 被正确跳转**；后续输出仍 echo\0e（stdout 空）→ 问题在 echo_main 内部。
- 下一个诊断：0x10520 加打印 argv[0]/argv[1] 字符串内容（本地基准 argv0='echo' argv1='hello'）。
  真机若 argv 对 → echo_main/musl stdio/syscall（elf-runner.c translate_syscall 与 test_emu 不同）；
  若 argv 错 → guest 字符串/栈问题。

## 2026-10-20 重大发现：echo_main 用直接 write(1)（非 FILE 指针）；真机 fd=2 是 error 路径先发
- **反汇编证实**：echo_main 0xabbd8 是 `write(1, buf, len)` 直接封装调用（0xabbd4 mov w0,#1 硬编码 fd=1；
  FILE 指针 0x13d380 只用于 0xabbd0 `str wzr,[x0]` 清零，非 fwrite 参数）。之前"fwrite FILE 诊断"读 x0=1 → 本地/真机 mem fault addr=0x1，已删。
- **真机 653d705 版**：第一个 write = `fd=2 n=13 buf='echo'`（stderr error 消息）——**echo_main 的 write(1,'hello') 从未执行**。
  → echo_main 内部（或之前）先走了 error 路径（bb_error_msg），busybox exit code=1（正常 echo 应 0）。
- **本地基准（安全诊断版）**：`[diag] echo-write fd=1 len=6` + `[diag] write fd=1 n=6 pc-off=0xf18a0 lr-off=0xf48a4 buf='hello` + `hello` 输出。
- **本轮构建带**：① echo_main 0xabbd8 安全诊断（fd/len，不读危险指针）② write svc 诊断加 **lr-off**（write 调用者）。
  **真机若 write lr-off=0xf48a4（同本地）→ stdio FILE/fd 层错；若不同 → 更早的 error 路径。**

## 2026-10-20 根因定位：elf-runner.c sys_brk 是 no-op → musl malloc 拿不到堆 → echo xmalloc 失败
- multi-diag 真机数据：`echo-main argc=2`（入口正确）、`write fd=2 lr-off=0xf48a4`（error 消息写 stderr——
  lr 与本地 fwrite 内部一致，但 echo 的 write(1) 从未执行）、`exit-path x19=7`（error 后退出）。
- echo-newline/echo-write/echo-ret 均未触发 → echo_main 在 0xabbb0 之前失败。
- **对照源码**：test_emu.c `case 214` 有 8MB mmap 堆 + brk 语义（brk(0)→cur；越界→旧 cur）；
  **elf-runner.c `sys_brk` 是 `(void)newbrk; return 0;`（no-op）→ musl malloc 小块分配失败/重叠 →
  busybox xmalloc → bb_error_msg → fd=2 error → exit 1。**
- **修复（commit 7ac21da 之后）**：elf-runner.c sys_brk 改为 16MB mmap 堆 + 标准 brk 语义。

## 2026-10-20 brk 修复后真机行为未变 → 需确认 xmalloc 失败调用者
- brk 堆修复版（6912102）真机结果：仍 fd=2 error、exit-path x19=7、echo 未到 write(1)。
  可能 ① 新包未生效（TrollStore 缓存/装错）② xmalloc 失败另有原因。
- 本轮新增：① elf-runner START 打印版本标记（ELF-RUNNER 2026-10-20 v7 brk-heap）确认包版本
  ② emu 一次性诊断：xmalloc(0x11a74) 入口打印 size+lr（本地基准 size=7 lr=0xabb9c）
  ③ bb_error_msg(0x10e7c) 入口打印 caller-lr + msg（本地不触发；真机将指出谁调了 error）

## 2026-10-20 v7 确认：brk 修复已装；xmalloc(malloc 0x85e0) 仍失败
- v7 版本标记确认 brk 堆已生效；xmalloc(0x11a74)=调 0x85e0(malloc)→NULL→0x11a28(xalloc_die)→stderr。
- 本地 malloc 序列（新诊断）：brk(0)→ret 堆基址 ✓；brk(扩展)→ret 新断点 ✓；mmap(固定0x...b000,0x1000)→ret 同址 ✓；mmap(NULL,0x1000)→ret 新区 ✓。
- **怀疑**：musl malloc 用 MAP_FIXED mmap 在 heap 顶附近固定地址；iOS MAP_FIXED 若地址已映射（栈/堆/段冲突）→ EINVAL → malloc NULL。
- 本轮带 brk/mmap 返回诊断（malloc-sys-ret）→ 真机看哪个 syscall 返回负值。

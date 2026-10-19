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

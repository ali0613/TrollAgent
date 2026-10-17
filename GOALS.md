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

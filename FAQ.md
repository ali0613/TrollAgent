# TrollAgent 常见问题（FAQ）

> 版本：v7.0.4+（iOS 16.3 / TrollStore）。遇到问题先看这里。

## 一、JIT 与性能

### Q1：TrollAgent 为什么需要 JIT？
统一环境（TrollRuntime）的翻译器（Asbestos）把 Linux ARM64 指令翻译到 iPhone 上执行。不开 JIT 时只能纯解释执行——能跑但很慢（v7.0.1 曾实测挂死）；开了 JIT 后翻译块缓存成原生代码，速度快一个量级（uname 从秒级降到 47ms 级）。

### Q2：JIT 会自动开启吗？
会。v7.0.4 起 App 启动自动做两件事（双保险）：
1. **ptrace 自 attach**（进程内尝试，无感、不闪切）
2. **无条件调 TrollStore URL**（`apple-magnifier://enable-jit`，由 TrollStore root 权限外部 attach——这是可靠路径）

首次执行 shell 命令前还会等待 3 秒，确保 JIT 授权就绪。

### Q3：为什么不能完全靠 App 自己开 JIT？
iOS 里**一个进程不能同步调试自己**（Husk 官方文档原话："A process cannot synchronously debug itself"）。要让内核放行可执行内存，必须由**另一个进程**（调试器 / root helper）attach 目标 App。所以：
- 自己 ptrace 自己（self-attach）：可能返回成功但内核并没有真正放行 JIT → 之后写 JIT 代码页就 **SIGBUS（Bus error: 10）** 闪退
- TrollStore URL：由 TrollStore 的 root helper **外部 attach**，放行有效（v7.0.3 手动开 JIT 实测 29/29 全通）

### Q4：打开后闪退 / 崩溃日志显示 "signal Bus error: 10" 怎么办？
SIGBUS = 内核拒绝访问 JIT 内存（KERN_PROTECTION_FAILURE），说明 JIT 授权没生效。排查顺序：
1. 确认装的是最新版（≥ v7.0.4.2，双保险修复版）
2. 打开 App 前先在 **TrollStore 里手动开一次 "Allow JIT"**（相当于兜底授权）
3. 确认系统 **开发者模式（Developer Mode）已开启**（iOS 16+ 开 JIT 的前提；TrollStore 安装时一般已自动处理）
4. 还闪退就把崩溃日志发出来（App 内：本机工具审计 → 崩溃日志 tab，或 iOS 设置 → 分析数据 → `TrollAgent-*.ips`）

### Q5：每次启动都要手动开 JIT 吗？
不用。v7.0.4.2 起自动开启（双保险 + 首条命令前等待）。TrollStore 的手动开关只作为兜底手段。

## 二、远程终端 / 连接

### Q6：远程终端服务怎么开启？
**设置 → 网络与抓包 → 远程终端服务 → 点"启动"**（显示"已启动 :8790"）。注意：**服务是手动启动的**，重装后默认关闭，不会自动开。

### Q7：为什么 App 明明开了服务，我却连不上？
最可能两种：
1. **App 进了后台**：iOS 会把退后台的 App 网络服务几秒内挂起。保持 App 前台（或开启抓包 VPN 保活）才能连。
2. **端口不对**：局域网直连手机用 `http://<手机IP>:8790`；经 N1 公网转发用的是 **18790**（`http://<N1公网IP>:18790`），不是 8790。

### Q8：连接地址在哪看？
App 内远程终端服务页会显示 `http://<手机IP>:8790` 和 token。API：`POST /api/tool`，body `{"name":"shell.exec","params":{"command":"...","timeout":N,"runtime":"ios"}}`，Header `Authorization: Bearer <token>`。`/health` 免认证可查存活。

### Q9：为什么装过抓包 VPN 后远程就连不上？
抓包 VPN 的隧道路由残留会"黑洞"局域网入站（8790）。关掉 VPN → 完全杀掉 App 重开 → 重新启动远程终端服务即可。

## 三、统一环境

### Q10：TrollRuntime 是模拟器吗？
不是。它不是 iSH 模拟器，是**统一环境**：Alpine Linux rootfs + Asbestos 翻译器（guest ARM64 → 原生/解释执行）。支持完整 shell 组合（管道 / `&&` / `;` / 循环 / 重定向），缺工具自动 `apk add`。

## 四、安装 / 更新

### Q14：怎么安装？
下载 `.tipa` → TrollStore → 安装 → 打开。升级安装会保留配置（同 bundle id 覆盖）。

### Q15：升级后设置会丢吗？
不会。配置存 UserDefaults/文档目录，覆盖安装保留。若异常（如端口占用），重启 App 即可。

## 五、界面 / 功能

### Q16：聊天框的终端按钮打开什么？
简易终端（黑底、`$` 提示符、走统一环境执行、30s 超时）——和 minis 的真终端一致。远程终端设置页仍在：设置 → 网络与抓包。

### Q17：崩溃日志 tab 的"清空"点了没反应？
v7.0.4 已修复（补了 tab3 分支 + clear 逻辑）。旧版升级到最新版即可。

### Q18：用量统计（图表图标）点进去闪退？
v7.0.4 已修复（`%@`+Int 格式崩溃点改 `%d`）。升级即可。

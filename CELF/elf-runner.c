/*
 * elf-runner.c — aarch64 Linux 静态 ELF 用户态运行时（WSL1 式）
 * 
 * 用法: elf-runner <linux-aarch64-static-elf> [args...]
 *
 * 原理（P5 核心，复用"指令集相同 + syscall 翻译"思路）:
 *   1. 解析静态 aarch64 ELF（e_machine=183），按 PT_LOAD 段 mmap 加载（指令集与 A15 相同→直跑）
 *   2. 扫描文本段，把 Linux 系统调用指令 `svc #0`(0xD4000001) patch 成 `brk #1`(0xD4200001)
 *      —— brk 在 iOS 触发 SIGTRAP(EXC_BREAKPOINT)，可在用户态捕获
 *   3. SIGTRAP handler 里从 ucontext 读 aarch64 寄存器: x16=syscall号, x0-x7=参数
 *   4. 翻译 syscall → 调用 iOS/libc 实现 → 写回 x0=返回值 → 恢复执行
 *   5. 按 Linux ABI 布置初始栈（argc/argv/envp）后跳转 e_entry
 *
 * 目标（首个验收）: 静态 busybox `echo hello` / `ls` / `cat` 原生直跑。
 * syscall 表从 write/exit/open/close/read 起步，逐步扩到文件/内存/进程/时间子集。
 *
 * 编译（iOS arm64）:
 *   xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=15.0 -O2 -o elf-runner elf-runner.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <time.h>
#include <sys/ucontext.h>
#include <dirent.h>
#include <sys/uio.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <poll.h>
#include <sched.h>       /* v19.18f: cpu_set_t（sched_getaffinity） */
#ifdef __APPLE__
#include <sys/mount.h>
#include <sys/sysctl.h>   /* Darwin: sysctl/CTL_KERN/KERN_BOOTTIME/CTL_HW/HW_MEMSIZE */
#include <mach/mach.h>    /* v19.18d: host_statistics64/vm_kernel_page_size（/proc/meminfo 用） */
#else
#include <sys/vfs.h>
#include <sys/sysinfo.h>
#include <sys/sendfile.h>   /* Linux sendfile 签名 */
#endif
#include <signal.h>
#include <setjmp.h>
/* iOS SDK 缺 sys/ptrace.h（ptrace 为 Darwin 私有 API）——手写声明与常量，符号在 libSystem */
#define PT_TRACE_ME   0
#define PT_ATTACHEXC  19
#define PT_DETACH     11
extern int ptrace(int request, pid_t pid, char *addr, int data);
#include <stdbool.h>
#include <stddef.h>
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif

/* ---- aarch64 ELF 常量 ---- */
#define ELF_MAGIC      0x464C457F   /* \x7fELF */
#define EM_AARCH64     183
#define PT_LOAD        1
#define PT_INTERP      3
#define PF_X           1
#define PF_W           2
#define PF_R           4

/* aarch64 指令 */
#define SVC_0          0xD4000001u  /* svc #0 —— Linux syscall */
#define BRK_1          0xD4200001u  /* brk #1 —— iOS SIGTRAP */

/* ---- ELF64 头结构（最小） ---- */
typedef struct {
    uint32_t magic;
    uint8_t  ei_class;      /* 2=ELFCLASS64 */
    uint8_t  ei_data;       /* 1=LSB */
    uint8_t  ei_version;
    uint8_t  ei_osabi;
    uint8_t  ei_abiversion;
    uint8_t  ei_pad[7];
    uint16_t e_type;
    uint16_t e_machine;
    uint32_t e_version;
    uint64_t e_entry;
    uint64_t e_phoff;
    uint64_t e_shoff;
    uint32_t e_flags;
    uint16_t e_ehsize;
    uint16_t e_phentsize;
    uint16_t e_phnum;
    uint16_t e_shentsize;
    uint16_t e_shnum;
    uint16_t e_shstrndx;
} Elf64_Ehdr;

typedef struct {
    uint32_t p_type;
    uint32_t p_flags;
    uint64_t p_offset;
    uint64_t p_vaddr;
    uint64_t p_paddr;
    uint64_t p_filesz;
    uint64_t p_memsz;
    uint64_t p_align;
} Elf64_Phdr;

typedef struct {
    uint32_t sh_name;
    uint32_t sh_type;
    uint64_t sh_flags;
    uint64_t sh_addr;
    uint64_t sh_offset;
    uint64_t sh_size;
    uint32_t sh_link;
    uint32_t sh_info;
    uint64_t sh_addralign;
    uint64_t sh_entsize;
} Elf64_Shdr;

typedef struct {
    uint64_t r_offset;
    uint64_t r_info;
    int64_t  r_addend;
} Elf64_Rela;

#define SHT_RELA           4
#define R_AARCH64_RELATIVE 1027  /* *(base+r_offset) = base + r_addend */

/* ---- 运行时状态 ---- */
uintptr_t g_base = 0;             /* 加载基址（存地址；按整数运算避免指针算术混用） */
static uintptr_t g_load_vaddr = 0;      /* 第一个段的 vaddr */
size_t   g_total_size = 0;       /* 覆盖全部段的内存区域大小 */
static uint64_t g_syscall_num = 0;      /* 由 svc patch 记录（brk 号带 syscall#） */
static uint64_t g_phoff = 0;           /* 14c8: program header 信息（auxv AT_PHDR/AT_PHENT/AT_PHNUM） */
static uint64_t g_phentsize = 0;
static uint64_t g_phnum = 0;

/* 段保护信息（patch 完成后统一 mprotect） */
#define MAX_SEGS 64
static struct { uintptr_t base; uintptr_t off; size_t len; int prot; } g_segs[MAX_SEGS];
/* v19.18j: 动态 ELF（PT_INTERP）——蓝本 iSH kernel/exec.c（GPL 只读参考，代码自研）
   M1: 加载 ld-musl 到独立基址，entry 指向 ld-musl；动态解析（DT_NEEDED/.so/重定位）由 guest 内 ld-musl 完成 */
static char g_interp_name[256] = {0};
/* v19.18j: interp 区基址/大小非 static（emu.c extern 引用 fetch OOB 检查） */
uintptr_t g_interp_base = 0;
size_t g_interp_size = 0;
static uintptr_t g_interp_entry = 0;
static uintptr_t g_app_entry = 0;   /* 动态模式：主程序 e_entry（auxv AT_ENTRY 用） */
static int g_nsegs = 0;
static int g_rwx = 0;      /* 14da: mmap 走 RWX 直连(allow-unsigned)时置 1——保持 RWX 直接执行，不再 mprotect */
static sigjmp_buf g_exit_jmp; /* 14dc: 主进程内跑模式的 ELF 退出出口（exit_group → siglongjmp 回） */
static int g_exit_jumped = 0;
/* v19.3.1 buildfix: 全局（非 static）——emu.c 用 extern 引用这两个符号，static 不导出导致
   链接 undefined symbol "_g_exit_code"/"_g_emu_halt"（本地 -c 单文件不链接测不出，iOS 链接必挂） */
int g_exit_code = 0;
int g_emu_halt = 0;

/* ---- 寄存器访问（iOS arm64 ucontext） ---- */
#if defined(__aarch64__)
#define REG_X(n)  (ctx->uc_mcontext->__ss.__x[n])
#define REG_SP    (ctx->uc_mcontext->__ss.__sp)
#define REG_PC    (ctx->uc_mcontext->__ss.__pc)
#define REG_SYSCALL (ctx->uc_mcontext->__ss.__x[16])
#endif

/* ---- syscall 翻译表（逐步扩展） ---- */

/* Linux aarch64 syscall 号（asm/unistd.h 子集） */
#define SYS_io_setup          0
#define SYS_exit              93
#define SYS_exit_group        94
#define SYS_set_tid_address   96
#define SYS_fcntl             25
#define SYS_faccessat         48
#define SYS_openat            56
#define SYS_close             57
#define SYS_read              63
#define SYS_write             64
#define SYS_lseek             62
#define SYS_mmap              222
#define SYS_munmap            215
#define SYS_brk               214
#define SYS_uname             160
#define SYS_umask             166
#define SYS_getpid            172
#define SYS_getuid            174
#define SYS_geteuid           175
#define SYS_getgid            176
#define SYS_getegid           177
#define SYS_getppid           173
#define SYS_nanosleep         101
#define SYS_gettimeofday      169
#define SYS_clock_gettime     113
#define SYS_statx             291
#define SYS_newfstatat        79
#define SYS_getdents64        61
#define SYS_writev             66
#define SYS_readlinkat        78
#define SYS_mkdirat           34
#define SYS_unlinkat          35
#define SYS_getcwd            17
#define SYS_renameat          38
#define SYS_renameat2         276
#define SYS_symlinkat         36
#define SYS_linkat            37
#define SYS_fchmodat          53
#define SYS_fchownat          54
#define SYS_truncate          45
#define SYS_ftruncate         46
#define SYS_utimensat         88
#define SYS_rmdir             21
#define SYS_chdir             49
#define SYS_dup               23
#define SYS_dup3              24
#define SYS_ioctl             29
#define SYS_arch_prctl        178  /* x86 专用，aarch64 无 */
#define SYS_fork              220  /* aarch64：httpd 每连接 fork 子进程 */
#define SYS_execve            221  /* aarch64：timeout/xargs/nice 的子进程 exec */
#define SYS_setpriority       140
#define SYS_sched_getaffinity 123
#define SYS_sched_setaffinity 122
#define SYS_fstat             80
#define SYS_pipe2             59
/* v19.18e：socket 族（网络类 applet：wget/nc/telnet/httpd 等） */
#define SYS_poll               7
#define SYS_select            23
#define SYS_socket            198
#define SYS_socketpair        199
#define SYS_bind              200
#define SYS_listen            201
#define SYS_accept            202
#define SYS_connect           203
#define SYS_getsockname       204
#define SYS_getpeername       205
#define SYS_sendto            206
#define SYS_recvfrom          207
#define SYS_setsockopt        208
#define SYS_getsockopt        209
#define SYS_shutdown          210
#define SYS_sendmsg           211
#define SYS_recvmsg           212
#define SYS_accept4           242

static long sys_exit_group(int code);   /* 前向声明（sys_exit 引用 sys_exit_group，须先声明） */
static long sys_exit(int code)          { return sys_exit_group(code); }
static long sys_exit_group(int code) {
    /* 14dc: 主进程内跑模式——ELF 的 exit/exit_group 不再 _exit 杀进程，
       siglongjmp 跳回 elf_runner_main 的 sigsetjmp 出口（信号 handler 上下文→主执行流），
       主进程(8790 服务)存活，后续命令可继续。 */
    if (g_exit_jumped) {
        g_exit_code = code;
        siglongjmp(g_exit_jmp, 1);
    }
    _exit(code);
    return 0;
}
static long sys_getpid(void)            { return (long)getpid(); }
static long sys_getppid(void)           { return (long)getppid(); }
static long sys_getuid(void)            { return 0; }
static long sys_geteuid(void)           { return 0; }
static long sys_getgid(void)            { return 0; }
static long sys_getegid(void)           { return 0; }
static mode_t g_guest_umask = 0022;     /* v19.18d：guest umask 模拟（cp -r 目录权限 bug 根因） */
static long sys_umask(mode_t mask) {
    mode_t old = g_guest_umask;
    g_guest_umask = mask & 0777;
    return (long)old;
}

/* ---- v19.18e：socket 族（网络 applet）----
 * guest 是 Linux ABI：struct sockaddr_in 无 sin_len、family 在偏移 0（uint16）。
 * iOS 是 Darwin ABI：sockaddr_in 有 sin_len(uint8)+sin_family(uint8)。
 * 本地 Linux 布局与 guest 相同直接透传；iOS 需逐字段转换。
 */
struct linux_sockaddr_in {
    uint16_t sin_family;
    uint16_t sin_port;      /* 网络序 */
    uint32_t sin_addr;
    char     sin_zero[8];
};
struct linux_sockaddr_in6 {
    uint16_t sin6_family;
    uint16_t sin6_port;
    uint32_t sin6_flowinfo;
    struct in6_addr sin6_addr;
    uint32_t sin6_scope_id;
};
static socklen_t sockaddr_conv(const void *guest_sa, socklen_t guest_len,
                               struct sockaddr_storage *host_out) {
#ifdef __APPLE__
    /* Darwin：sockaddr_in = sin_len(1)+sin_family(1)+port(2)+addr(4) */
    if (guest_len >= sizeof(struct linux_sockaddr_in)) {
        const struct linux_sockaddr_in *g = guest_sa;
        struct sockaddr_in *h = (struct sockaddr_in *)host_out;
        memset(h, 0, sizeof(*h));
        h->sin_len = sizeof(*h);
        h->sin_family = g->sin_family;
        h->sin_port = g->sin_port;
        h->sin_addr.s_addr = g->sin_addr;
        return sizeof(*h);
    }
    if (guest_len >= sizeof(struct linux_sockaddr_in6)) {
        const struct linux_sockaddr_in6 *g = guest_sa;
        struct sockaddr_in6 *h = (struct sockaddr_in6 *)host_out;
        memset(h, 0, sizeof(*h));
        h->sin6_len = sizeof(*h);
        h->sin6_family = g->sin6_family;
        h->sin6_port = g->sin6_port;
        h->sin6_flowinfo = g->sin6_flowinfo;
        h->sin6_addr = g->sin6_addr;
        h->sin6_scope_id = g->sin6_scope_id;
        return sizeof(*h);
    }
    /* AF_UNIX 等：直接透传 */
    memcpy(host_out, guest_sa, guest_len);
    return guest_len;
#else
    /* Linux：guest 与宿主布局一致，直接透传 */
    memcpy(host_out, guest_sa, guest_len);
    return guest_len;
#endif
}
static long sys_socket(int domain, int type, int proto) {
    int fd = socket(domain, type, proto);
    return (fd < 0) ? -errno : (long)fd;
}
static long sys_socketpair(int domain, int type, int proto, int *sv) {
    int pair[2];
    if (socketpair(domain, type, proto, pair)) return -errno;
    sv[0] = pair[0]; sv[1] = pair[1];
    return 0;
}
static long sys_connect(int fd, const void *sa, socklen_t len) {
    struct sockaddr_storage hsa;
    socklen_t hlen = sockaddr_conv(sa, len, &hsa);
    if (connect(fd, (struct sockaddr *)&hsa, hlen)) {
        if (getenv("NET_DBG")) fprintf(stderr, "[conn] fd=%d hlen=%u family=%d errno=%d sa=%p\n",
            fd, (unsigned)hlen, ((struct sockaddr*)&hsa)->sa_family, errno, sa);
        return -errno;
    }
    return 0;
}
static long sys_bind(int fd, const void *sa, socklen_t len) {
    struct sockaddr_storage hsa;
    socklen_t hlen = sockaddr_conv(sa, len, &hsa);
    if (bind(fd, (struct sockaddr *)&hsa, hlen)) return -errno;
    return 0;
}
static long sys_getsockname(int fd, void *sa, socklen_t *len) {
    struct sockaddr_storage hsa;
    socklen_t hlen = sizeof(hsa);
    if (getsockname(fd, (struct sockaddr *)&hsa, &hlen)) return -errno;
#ifdef __APPLE__
    /* Darwin→Linux：去掉 sin_len，family 转 uint16 */
    if (hlen >= sizeof(struct sockaddr_in) && *len >= sizeof(struct linux_sockaddr_in)
        && ((struct sockaddr_in *)&hsa)->sin_family == AF_INET) {
        struct linux_sockaddr_in *g = (struct linux_sockaddr_in *)sa;
        const struct sockaddr_in *h = (const struct sockaddr_in *)&hsa;
        g->sin_family = h->sin_family; g->sin_port = h->sin_port;
        g->sin_addr = h->sin_addr.s_addr; memset(g->sin_zero, 0, 8);
        *len = sizeof(struct linux_sockaddr_in);
        return 0;
    }
#endif
    memcpy(sa, &hsa, *len < hlen ? *len : hlen);
    *len = hlen;
    return 0;
}
static long sys_getpeername(int fd, void *sa, socklen_t *len) {
    struct sockaddr_storage hsa;
    socklen_t hlen = sizeof(hsa);
    if (getpeername(fd, (struct sockaddr *)&hsa, &hlen)) return -errno;
#ifdef __APPLE__
    if (hlen >= sizeof(struct sockaddr_in) && *len >= sizeof(struct linux_sockaddr_in)
        && ((struct sockaddr_in *)&hsa)->sin_family == AF_INET) {
        struct linux_sockaddr_in *g = (struct linux_sockaddr_in *)sa;
        const struct sockaddr_in *h = (const struct sockaddr_in *)&hsa;
        g->sin_family = h->sin_family; g->sin_port = h->sin_port;
        g->sin_addr = h->sin_addr.s_addr; memset(g->sin_zero, 0, 8);
        *len = sizeof(struct linux_sockaddr_in);
        return 0;
    }
#endif
    memcpy(sa, &hsa, *len < hlen ? *len : hlen);
    *len = hlen;
    return 0;
}
static long sys_listen(int fd, int backlog) {
    if (listen(fd, backlog)) return -errno;
    return 0;
}
static long sys_accept(int fd, void *sa, socklen_t *len, int flags) {
    struct sockaddr_storage hsa;
    socklen_t hlen = sizeof(hsa);
    int c;
#ifdef __APPLE__
    c = accept(fd, (struct sockaddr *)&hsa, &hlen);
#else
    c = (flags & 3) ? accept4(fd, (struct sockaddr *)&hsa, &hlen, flags & 3) : accept(fd, (struct sockaddr *)&hsa, &hlen);
#endif
    if (c < 0) return -errno;
#ifdef __APPLE__
    if (sa && *len >= sizeof(struct linux_sockaddr_in)
        && hlen >= sizeof(struct sockaddr_in)
        && ((struct sockaddr_in *)&hsa)->sin_family == AF_INET) {
        struct linux_sockaddr_in *g = (struct linux_sockaddr_in *)sa;
        const struct sockaddr_in *h = (const struct sockaddr_in *)&hsa;
        g->sin_family = h->sin_family; g->sin_port = h->sin_port;
        g->sin_addr = h->sin_addr.s_addr; memset(g->sin_zero, 0, 8);
        if (len) *len = sizeof(struct linux_sockaddr_in);
    } else if (sa) { memcpy(sa, &hsa, *len < hlen ? *len : hlen); if (len) *len = hlen; }
#else
    if (sa && len) { memcpy(sa, &hsa, *len < hlen ? *len : hlen); *len = hlen; }
#endif
    return c;
}
static long sys_sendto(int fd, const void *buf, size_t n, int flags,
                       const void *sa, socklen_t len) {
    ssize_t rv;
    if (sa) {
        struct sockaddr_storage hsa;
        socklen_t hlen = sockaddr_conv(sa, len, &hsa);
        rv = sendto(fd, buf, n, flags, (struct sockaddr *)&hsa, hlen);
    } else rv = sendto(fd, buf, n, flags, NULL, 0);
    return (rv < 0) ? -errno : (long)rv;
}
static long sys_recvfrom(int fd, void *buf, size_t n, int flags,
                         void *sa, socklen_t *len) {
    ssize_t rv;
    if (sa) {
        struct sockaddr_storage hsa;
        socklen_t hlen = sizeof(hsa);
        rv = recvfrom(fd, buf, n, flags, (struct sockaddr *)&hsa, &hlen);
        if (rv >= 0) {
#ifdef __APPLE__
            if (hlen >= sizeof(struct sockaddr_in) && *len >= sizeof(struct linux_sockaddr_in)
                && ((struct sockaddr_in *)&hsa)->sin_family == AF_INET) {
                struct linux_sockaddr_in *g = (struct linux_sockaddr_in *)sa;
                const struct sockaddr_in *h = (const struct sockaddr_in *)&hsa;
                g->sin_family = h->sin_family; g->sin_port = h->sin_port;
                g->sin_addr = h->sin_addr.s_addr; memset(g->sin_zero, 0, 8);
                *len = sizeof(struct linux_sockaddr_in);
            } else { memcpy(sa, &hsa, *len < hlen ? *len : hlen); *len = hlen; }
#else
            memcpy(sa, &hsa, *len < hlen ? *len : hlen); *len = hlen;
#endif
        }
    } else rv = recvfrom(fd, buf, n, flags, NULL, NULL);
    return (rv < 0) ? -errno : (long)rv;
}
static long sys_setsockopt(int fd, int level, int opt, const void *val, socklen_t len) {
    if (setsockopt(fd, level, opt, val, len)) return -errno;
    return 0;
}
static long sys_getsockopt(int fd, int level, int opt, void *val, socklen_t *len) {
    if (getsockopt(fd, level, opt, val, len)) return -errno;
    return 0;
}
static long sys_shutdown(int fd, int how) {
    if (shutdown(fd, how)) return -errno;
    return 0;
}
static long sys_sendmsg(int fd, const struct msghdr *msg, int flags) {
    /* guest msghdr/iovec 与 Linux 布局一致；Darwin 的 msghdr 也兼容（msg_name/msg_iov 等） */
    struct msghdr h;
    memcpy(&h, msg, sizeof(h));
#ifdef __APPLE__
    if (msg->msg_name && msg->msg_namelen) {
        struct sockaddr_storage hsa;
        h.msg_namelen = sockaddr_conv(msg->msg_name, msg->msg_namelen, &hsa);
        h.msg_name = &hsa;
    }
#endif
    ssize_t rv = sendmsg(fd, &h, flags);
    return (rv < 0) ? -errno : (long)rv;
}
static long sys_recvmsg(int fd, struct msghdr *msg, int flags) {
    struct msghdr h;
    memcpy(&h, msg, sizeof(h));
    ssize_t rv = recvmsg(fd, &h, flags);
    if (rv < 0) return -errno;
#ifdef __APPLE__
    if (h.msg_name && h.msg_namelen) {
        struct sockaddr_storage *hsa = (struct sockaddr_storage *)h.msg_name;
        if (h.msg_namelen >= sizeof(struct sockaddr_in)
            && ((struct sockaddr_in *)hsa)->sin_family == AF_INET) {
            struct linux_sockaddr_in *g = (struct linux_sockaddr_in *)msg->msg_name;
            const struct sockaddr_in *hi = (const struct sockaddr_in *)hsa;
            g->sin_family = hi->sin_family; g->sin_port = hi->sin_port;
            g->sin_addr = hi->sin_addr.s_addr; memset(g->sin_zero, 0, 8);
            msg->msg_namelen = sizeof(struct linux_sockaddr_in);
        } else if (h.msg_namelen <= msg->msg_namelen) {
            memcpy(msg->msg_name, h.msg_name, h.msg_namelen);
            msg->msg_namelen = h.msg_namelen;
        }
    } else msg->msg_namelen = 0;
    msg->msg_flags = h.msg_flags;
#endif
    return (long)rv;
}
static long sys_poll(struct pollfd *fds, nfds_t nfds, int timeout) {
    int rv = poll(fds, nfds, timeout);
    return (rv < 0) ? -errno : (long)rv;
}
static long sys_getcwd(char *buf, size_t size) {
    if (!getcwd(buf, size)) return -errno;
    return (long)strlen(buf);
}
static long sys_mkdirat(int dirfd, const char *path, mode_t mode) {
    if (mkdirat(dirfd, path, mode)) return -errno;
    return 0;
}
static long sys_unlinkat(int dirfd, const char *path, int flags) {
    if (flags & 0x200 /* AT_REMOVEDIR：Linux 专有，Darwin 无此语义，转 rmdir */) {
        if (dirfd != -100 /* AT_FDCWD（Linux 值；iOS 宿主 AT_FDCWD=-2 会误判 → 真机 rmdir EINVAL） */) return -EINVAL;
        if (rmdir(path)) return -errno;
        return 0;
    }
    if (unlinkat(dirfd, path, flags)) return -errno;
    return 0;
}
static long sys_renameat(int olddfd, const char *oldp, int newdfd, const char *newp) {
    if (renameat(olddfd, oldp, newdfd, newp)) return -errno;
    return 0;
}
static long sys_renameat2(int olddfd, const char *oldp, int newdfd, const char *newp, unsigned flags) {
    /* renameat2 是 Linux 专用（RENAME_NOREPLACE/RENAME_EXCHANGE 等），iOS SDK 无此函数，
       直接调用 → implicit-function-declaration，clang 16+（Xcode 16+）下是硬错误，整包编译失败。
       flags==0 时语义等价于 POSIX renameat（iOS 有）；非 0 时 iOS 无对应语义，返回 ENOSYS。 */
    if (flags) return -ENOSYS;
    if (renameat(olddfd, oldp, newdfd, newp)) return -errno;
    return 0;
}
/* v19.18c：元数据类 syscall 翻译（touch/ln/chmod/chown/truncate 等此前 ENOSYS → "Function not implemented"） */
static long sys_symlinkat(const char *target, int newdirfd, const char *linkpath) {
    if (symlinkat(target, newdirfd, linkpath)) return -errno;
    return 0;
}
static long sys_linkat(int olddfd, const char *oldp, int newdfd, const char *newp, unsigned flags) {
    if (flags) return -ENOSYS;   /* AT_SYMLINK_FOLLOW 等 iOS 语义差异 */
    if (linkat(olddfd, oldp, newdfd, newp, 0)) return -errno;
    return 0;
}
static long sys_fchmodat(int dirfd, const char *path, mode_t mode) {
    if (getenv("TRACE_CHMOD")) fprintf(stderr, "[chmod] fchmodat(%d, '%s', 0%o)\n", dirfd, path, mode);
    if (fchmodat(dirfd, path, mode, 0)) return -errno;
    return 0;
}
static long sys_fchownat(int dirfd, const char *path, uid_t uid, gid_t gid, int flags) {
    if (fchownat(dirfd, path, uid, gid, flags)) return -errno;
    return 0;
}
static long sys_truncate(const char *path, off_t len) {
    if (truncate(path, len)) return -errno;
    return 0;
}
static long sys_ftruncate(int fd, off_t len) {
    if (ftruncate(fd, len)) return -errno;
    return 0;
}
static long sys_utimensat(int dirfd, const char *path, const struct timespec times[2], int flags) {
    if (utimensat(dirfd, path, times, flags)) return -errno;
    return 0;
}

static long sys_write(int fd, const void *buf, size_t count) {
    return (long)write(fd, buf, count);
}
static long sys_read(int fd, void *buf, size_t count) {
    return (long)read(fd, buf, count);
}
static DIR *g_dir_cache[16];   /* getdents64：fdopendir 缓存（busybox close 时释放） */
static long sys_close(int fd) {
    if (fd >= 0 && fd < 16 && g_dir_cache[fd]) {
        closedir(g_dir_cache[fd]);
        g_dir_cache[fd] = NULL;
        return 0;   /* DIR 接管 fd，closedir 已释放 */
    }
    return (long)close(fd);
}
static long sys_lseek(int fd, off_t off, int whence) {
    return (long)lseek(fd, off, whence);
}

/* Linux aarch64 O_* → Darwin O_*（busybox 按 Linux 常量传；Darwin 常量不同） */
static int xlate_flags(int lf) {
    int x = lf & 0x3;                 /* O_RDONLY/O_WRONLY/O_RDWR 一致 */
    if (lf & 0x40)   x |= O_CREAT;    /* 0x40 → 0x200 */
    if (lf & 0x80)   x |= O_EXCL;     /* 0x80 → 0x800 */
    if (lf & 0x200)  x |= O_TRUNC;    /* 0x200 → 0x400 */
    if (lf & 0x400)  x |= O_APPEND;   /* 0x400 → 0x8 */
    if (lf & 0x800)  x |= O_NONBLOCK; /* 0x800 → 0x4 */
    if (lf & 0x4000) x |= O_DIRECTORY;/* 0x4000 → 0x100000 */
    if (lf & 0x8000) x |= O_NOFOLLOW; /* 0x8000 → 0x100 */
    if (lf & 0x80000) x |= O_CLOEXEC; /* 0x80000 → 0x1000000 */
    return x;                         /* O_LARGEFILE(0x20000)：Darwin 无 */
}
/* Linux AT_* → Darwin AT_* */
static int xlate_atflags(int f) {
    int x = 0;
    if (f & 0x100)  x |= AT_SYMLINK_NOFOLLOW;  /* 0x100 → 0x20 */
    if (f & 0x200)  x |= AT_REMOVEDIR;         /* 0x200 → 0x80 */
    if (f & 0x2000) x |= AT_EACCESS;           /* 0x2000 → 0x10 */
    return x;
}
/* aarch64 Linux struct stat（asm-generic，musl 同布局，128B） */
struct linux_stat {
    uint64_t st_dev, st_ino;
    uint32_t st_mode, st_nlink, st_uid, st_gid;
    uint64_t st_rdev, __pad1;
    int64_t st_size;
    int32_t st_blksize, __pad2;
    int64_t st_blocks;
    int64_t atime_s; uint64_t atime_ns;
    int64_t mtime_s; uint64_t mtime_ns;
    int64_t ctime_s; uint64_t ctime_ns;
    uint32_t __resv[2];
};
/* v19.18c：is_proc_path 前移（sys_newfstatat 需要，原定义在 vproc 区导致隐式声明冲突） */
static int is_proc_path(const char *p) {
    if (!p) return 0;
    return strncmp(p, "/proc", 5) == 0 && (p[5] == '\0' || p[5] == '/');
}
static long sys_newfstatat(int dirfd, const char *path, struct linux_stat *st, int flags) {
    /* v19.18c：虚拟 /proc——stat(/proc[/*]) 在 iOS 无真实文件，返回虚拟目录/文件类型
       （busybox ls/ps 先 stat 目录，缺失 → ENOENT → ls /proc 失败、ps 枚举 0） */
    if (path && is_proc_path(path)) {
        memset(st, 0, sizeof(*st));
        int is_dir = (path[5] == '\0') || (path[5] == '/' && !path[6])
                  || (path[5] == '/' && path[6] >= '0' && path[6] <= '9');  /* /proc 或 /proc/<pid> */
        st->st_mode = (is_dir ? S_IFDIR : S_IFREG) | 0444;
        st->st_nlink = 1;
        st->st_ino = 1;
        return 0;
    }
    struct stat s;
    if (getenv("FSTAT_TRACE")) fprintf(stderr, "[fst] fstatat(dfd=%d path='%s' flags=%d)\n", dirfd, path, flags);
    if (fstatat(dirfd, path, &s, xlate_atflags(flags)) != 0) return -errno;
    memset(st, 0, sizeof(*st));
    st->st_dev = s.st_dev; st->st_ino = s.st_ino; st->st_mode = s.st_mode;
    st->st_nlink = s.st_nlink; st->st_uid = s.st_uid; st->st_gid = s.st_gid;
    st->st_rdev = s.st_rdev; st->st_size = s.st_size;
    st->st_blksize = s.st_blksize; st->st_blocks = s.st_blocks;
#ifdef __APPLE__
    st->atime_s = s.st_atimespec.tv_sec; st->atime_ns = s.st_atimespec.tv_nsec;
    st->mtime_s = s.st_mtimespec.tv_sec; st->mtime_ns = s.st_mtimespec.tv_nsec;
    st->ctime_s = s.st_ctimespec.tv_sec; st->ctime_ns = s.st_ctimespec.tv_nsec;
#else
    st->atime_s = s.st_atim.tv_sec; st->atime_ns = s.st_atim.tv_nsec;
    st->mtime_s = s.st_mtim.tv_sec; st->mtime_ns = s.st_mtim.tv_nsec;
    st->ctime_s = s.st_ctim.tv_sec; st->ctime_ns = s.st_ctim.tv_nsec;
#endif
    return 0;
}
/* Darwin 无 Linux 式 getdents64：getdirentries 读 Darwin dirent → 转 Linux dirent64 */
struct linux_dirent64 {
    uint64_t d_ino; int64_t d_off;
    uint16_t d_reclen; uint8_t d_type; char d_name[];
} __attribute__((packed));

/* ---- 虚拟 procfs（iOS 无 /proc；busybox ps 枚举 PID + 读 stat/cmdline） ---- */
#define VPROC_BASE  1000
#define VPROC_MAX   64
struct vproc_fd {
    int in_use;
    int is_dir;          /* 目录：getdents64 时枚举 pid */
    char *data;          /* 文件内容 */
    size_t len, pos;
};
static struct vproc_fd g_vproc[VPROC_MAX];
static int vproc_alloc(void) {
    for (int i = 0; i < VPROC_MAX; i++) {
        if (!g_vproc[i].in_use) {
            memset(&g_vproc[i], 0, sizeof(g_vproc[0]));
            g_vproc[i].in_use = 1;
            return VPROC_BASE + i;
        }
    }
    return -1;
}
static struct vproc_fd *vproc_get(int fd) {
    if (fd < VPROC_BASE || fd >= VPROC_BASE + VPROC_MAX) return NULL;
    struct vproc_fd *v = &g_vproc[fd - VPROC_BASE];
    return v->in_use ? v : NULL;
}
static void vproc_free(int fd) {
    struct vproc_fd *v = vproc_get(fd);
    if (v) { free(v->data); memset(v, 0, sizeof(*v)); }
}

/* 虚拟目录 fd（/proc）：getdents64 时枚举 pid */
static long vproc_open_dir(void) {
    int fd = vproc_alloc();
    if (fd < 0) return -EMFILE;
    vproc_get(fd)->is_dir = 1;
    return fd;
}
/* 生成 /proc/<pid>/stat 与 /proc/<pid>/cmdline 内容 */
static long vproc_open(const char *path, int flags) {
    (void)flags;
    if (!path[5] || (path[5] == '/' && !path[6])) return vproc_open_dir();  /* /proc 或 /proc/ */
    const char *rest = path + 6;
    long pid = -1;
    if (strncmp(rest, "self/", 5) == 0) { pid = (long)getpid(); rest += 5; }
    else {
        char *end;
        pid = strtol(rest, &end, 10);
        if (end != rest && *end == '/') {
            rest = end + 1;
        } else if (strcmp(rest, "mounts") == 0 || strcmp(rest, "uptime") == 0
                   || strcmp(rest, "meminfo") == 0) {
            pid = -1;   /* v19.18c：顶层文件 /proc/mounts、/proc/uptime、/proc/meminfo（无 pid 前缀） */
        } else return -ENOENT;
    }
    int fd = vproc_alloc();
    if (fd < 0) return -EMFILE;
    struct vproc_fd *v = vproc_get(fd);
    char name[64] = "";
    /* v19.18: iOS SDK 无 libproc.h（proc_name/proc_pidinfo/proc_listallpids 不可用）——
       统一占位进程名 p<pid>，ps 框架可跑；真实进程名后续单独研究（sysctl KERN_PROC 沙盒受限） */
    snprintf(name, sizeof(name), "p%ld", pid);
    if (strcmp(rest, "stat") == 0 && pid >= 0) {
        char buf[512];
#ifndef __APPLE__
        /* v19.18g：本地（Linux 宿主）读真实 /proc/<pid>/stat——pgrep/ps 需真实 comm */
        char p[64];
        snprintf(p, sizeof(p), "/proc/%ld/stat", pid);
        int fh = open(p, O_RDONLY);
        if (fh >= 0) {
            ssize_t n = read(fh, buf, sizeof(buf) - 1);
            close(fh);
            if (n > 0) { buf[n] = 0; v->data = strdup(buf); v->len = n; return fd; }
        }
        /* 读不到（进程消失/权限）→ 占位 */
        snprintf(buf, sizeof(buf), "%ld (?) R 0 0 0 0 0 0 0 0 0 0 0 0 0 20 0 0 0 0 0", pid);
#else
        long utime = 0, stime = 0, ppid = 0;
        int nthreads = 0;
        /* Linux /proc/<pid>/stat 关键字段位：pid (comm) state ppid ... utime stime ... num_threads */
        snprintf(buf, sizeof(buf),
                 "%ld (%s) S %ld 0 0 0 0 0 0 0 0 0 %ld %ld 0 0 20 0 %d 0 0 0 0 0",
                 pid, name[0] ? name : "?", ppid, utime, stime, nthreads);
#endif
        v->data = strdup(buf);
        v->len = strlen(buf);
        return fd;
    }
    if (strcmp(rest, "cmdline") == 0 && pid >= 0) {
#ifndef __APPLE__
        /* v19.18g：本地读真实 cmdline（pgrep -f 匹配需要） */
        char p[64];
        snprintf(p, sizeof(p), "/proc/%ld/cmdline", pid);
        int fh = open(p, O_RDONLY);
        if (fh >= 0) {
            char cb[2048];
            ssize_t n = read(fh, cb, sizeof(cb) - 1);
            close(fh);
            if (n > 0) {
                /* cmdline 以 \0 分隔参数；busybox pgrep -f 匹配完整串——\0 换空格 */
                for (ssize_t i = 0; i < n; i++) if (cb[i] == 0) cb[i] = ' ';
                v->data = strdup(cb);
                v->len = n;
                return fd;
            }
        }
        v->data = strdup("");
        v->len = 0;
#else
        v->data = strdup(name[0] ? name : "?");
        v->len = strlen(v->data);
#endif
        return fd;
    }
    if (strcmp(rest, "uptime") == 0) {
        char buf[64];
#ifdef __APPLE__
        struct timeval boot, now;
        size_t blen = sizeof(boot);
        int mib[2] = { CTL_KERN, KERN_BOOTTIME };
        if (sysctl(mib, 2, &boot, &blen, NULL, 0) == 0) {
            gettimeofday(&now, NULL);
            snprintf(buf, sizeof(buf), "%.2f %.2f",
                     (double)(now.tv_sec - boot.tv_sec),
                     (double)(now.tv_sec - boot.tv_sec) * 0.5);
        } else snprintf(buf, sizeof(buf), "0.00 0.00");
#else
        snprintf(buf, sizeof(buf), "0.00 0.00");
#endif
        v->data = strdup(buf);
        v->len = strlen(v->data);
        return fd;
    }
    if (strcmp(rest, "mounts") == 0) {              /* v19.18c：df 读 /proc/self/mounts 匹配挂载点 */
        v->data = strdup("/dev/root / ext4 rw,relatime 0 0\n"
                         "/dev/root /tmp ext4 rw,relatime 0 0\n"
                         "/dev/root /var ext4 rw,relatime 0 0\n"
                         "/dev/root /private/var ext4 rw,relatime 0 0\n");
        v->len = strlen(v->data);
        return fd;
    }
    if (strcmp(rest, "meminfo") == 0) {             /* v19.18d：free 读 /proc/meminfo——iOS 无真实 meminfo，用 sysctl 填充 */
        char buf[1024];
        unsigned long long total = 0, free_mem = 0, avail = 0;
#ifdef __APPLE__
        int mib[2] = { CTL_HW, HW_MEMSIZE };
        size_t len = sizeof(total);
        if (sysctl(mib, 2, &total, &len, NULL, 0) != 0) total = 0;
        /* vm_statistics64：页面数（iOS 沙盒可读） */
        mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
        vm_statistics64_data_t vs;
        if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vs, &cnt) == KERN_SUCCESS) {
            uint64_t ps = (uint64_t)vm_kernel_page_size;
            if (!ps) ps = 16384;
            free_mem = vs.free_count * ps;
            avail = (vs.free_count + vs.inactive_count) * ps;
        }
#endif
        if (!total) total = 8ULL << 30;             /* 兜底 8GB */
        if (!avail) avail = free_mem ? free_mem : total / 4;
        snprintf(buf, sizeof(buf),
                 "MemTotal:      %8llu kB\n"
                 "MemFree:       %8llu kB\n"
                 "MemAvailable:  %8llu kB\n"
                 "Buffers:              0 kB\n"
                 "Cached:               0 kB\n"
                 "SwapTotal:            0 kB\n"
                 "SwapFree:             0 kB\n",
                 total / 1024, free_mem / 1024, avail / 1024);
        v->data = strdup(buf);
        v->len = strlen(buf);
        return fd;
    }
    /* 其他 /proc/<pid>/xxx：空文件（后续按需扩展） */
    v->data = strdup("");
    v->len = 0;
    return fd;
}
/* 虚拟目录 getdents64：枚举所有 pid */
static long vproc_getdents(int fd, void *buf, size_t count) {
    struct vproc_fd *v = vproc_get(fd);
    if (!v || !v->is_dir) return -EBADF;
    pid_t pids[4096];
    int n = 0;
    /* v19.18: iOS 无 proc_listallpids（libproc.h 不存在）——占位枚举 1..256 */
#ifdef __APPLE__
    for (n = 0; n < 4096 && n < 256; n++) pids[n] = (pid_t)(n + 1);
#else
    /* 本地对照：枚举宿主 /proc 的 pid 目录 */
    DIR *dp = opendir("/proc");
    if (dp) {
        struct dirent *de;
        while (n < 4096 && (de = readdir(dp)) != NULL) {
            char *end;
            long pid = strtol(de->d_name, &end, 10);
            if (*end == '\0' && pid > 0) pids[n++] = (pid_t)pid;
        }
        closedir(dp);
    }
#endif
    if (n < 0) n = 0;
    unsigned char *out = buf;
    size_t used = 0;
    while ((size_t)v->pos < (size_t)n) {
        char name[16];
        snprintf(name, sizeof(name), "%d", pids[v->pos]);
        size_t nl = strlen(name);
        size_t lreclen = offsetof(struct linux_dirent64, d_name) + nl + 1;
        if (used + lreclen > count) break;
        struct linux_dirent64 *ld = (struct linux_dirent64 *)(out + used);
        ld->d_ino = (uint64_t)pids[v->pos];
        ld->d_off = (int64_t)v->pos + 1;
        ld->d_reclen = (uint16_t)lreclen;
        ld->d_type = 4 /* DT_DIR */;
        memcpy(ld->d_name, name, nl + 1);
        used += lreclen;
        v->pos++;
    }
    if (used == 0 && (size_t)v->pos >= (size_t)n) return 0;  /* EOF */
    return (long)used;
}
/* 虚拟文件 read/lseek/close */
static long vproc_read(int fd, void *buf, size_t count) {
    struct vproc_fd *v = vproc_get(fd);
    if (!v || v->is_dir) return -EBADF;
    if (v->pos >= v->len) return 0;
    size_t n = v->len - v->pos;
    if (n > count) n = count;
    memcpy(buf, v->data + v->pos, n);
    v->pos += n;
    return (long)n;
}
static long vproc_lseek(int fd, off_t off, int whence) {
    struct vproc_fd *v = vproc_get(fd);
    if (!v || v->is_dir) return -ESPIPE;
    off_t base = (whence == SEEK_SET) ? 0 : (whence == SEEK_CUR) ? (off_t)v->pos : (off_t)v->len;
    off_t np = base + off;
    if (np < 0) return -EINVAL;
    if (np > (off_t)v->len) np = (off_t)v->len;
    v->pos = (size_t)np;
    return np;
}
static long vproc_close(int fd) {
    if (!vproc_get(fd)) return -EBADF;
    vproc_free(fd);
    return 0;
}
static long sys_getdents64(int fd, void *buf, size_t count) {
#ifdef __APPLE__
    /* Darwin 无 Linux getdents64、getdirentries 在 64 位 inode 下不可用：
       fdopendir+readdir（Darwin dirent → 转 Linux dirent64）；DIR 按 fd 缓存，
       sys_close 负责释放，避免 busybox 后续 close(fd) 时 double-close。 */
    if (fd < 0 || fd >= 16) return -EBADF;
    if (!g_dir_cache[fd]) {
        g_dir_cache[fd] = fdopendir(fd);
        if (!g_dir_cache[fd]) return -errno;
    }
    DIR *d = g_dir_cache[fd];
    unsigned char *out = buf;
    long o = 0;
    struct dirent *de;
    errno = 0;
    while ((de = readdir(d)) != NULL) {
        size_t namlen = strlen(de->d_name);
        size_t lreclen = (namlen + 1 + 19 + 7) & ~(size_t)7;
        if (o + (long)lreclen > (long)count) break;
        memset(out + o, 0, lreclen);
        struct linux_dirent64 *ld = (struct linux_dirent64 *)(out + o);
        ld->d_ino = (uint64_t)de->d_ino;
        ld->d_off = (int64_t)o;   /* Linux d_off：busybox 一般不依赖精确值 */
        ld->d_reclen = (uint16_t)lreclen;
        ld->d_type = de->d_type;
        memcpy(ld->d_name, de->d_name, namlen);
        o += (long)lreclen;
    }
    return o;
#else
    /* 本地对照：Linux 原生 getdents64 透传（布局即 Linux dirent64） */
    long r = syscall(217, fd, buf, count);   /* x86_64 getdents64 */
    if (getenv("GDD_TRACE")) {
        fprintf(stderr, "[gdd] fd=%d count=%zu ret=%ld\n", fd, count, r);
        if (r > 0) {
            unsigned char *b = buf;
            for (int k = 0; k < (r < 48 ? r : 48); k++) {
                fprintf(stderr, "%02x%c", b[k], (k % 16 == 15) ? '\n' : ' ');
            }
            fprintf(stderr, "\n");
            struct { unsigned long ino, off; unsigned short reclen; unsigned char type; char nm[64]; } *d = buf;
            fprintf(stderr, "[gdd] d0: ino=%lu reclen=%u type=%u name='%s'\n",
                    d->ino, d->reclen, d->type, d->nm);
        }
    }
    return r < 0 ? -errno : r;
#endif
}
/* readv：guest/host iovec 布局一致（base+len 各 8 字节），直接透传 */
static long sys_readv(int fd, const struct iovec *iov, int iovcnt) {
    return (long)readv(fd, iov, iovcnt);
}
static long sys_writev(int fd, const struct iovec *iov, int iovcnt) {
    return (long)writev(fd, iov, iovcnt);
}
static long sys_openat(int dirfd, const char *path, int flags, mode_t mode) {
    int x = xlate_flags(flags);
    if (getenv("OAT_TRACE")) {
        fprintf(stderr, "[oat] dirfd=%d path=%s flags=0x%x -> xlate 0x%x mode=0%o\n",
                dirfd, path ? path : "(null)", flags, x, (unsigned)mode);
    }
    return (long)openat(dirfd, path, x, mode);
}
static long sys_faccessat(int dirfd, const char *path, int amode) {
    return (long)faccessat(dirfd, path, amode, 0);   /* Darwin 4 参（flags） */
}
static long sys_dup(int fd) {
    return (long)dup(fd);
}
static long sys_chdir(const char *path) {
    if (chdir(path)) return -errno;
    return 0;
}
/* v19.18f：execve——只发生在 fork 子进程（xargs/timeout/nice 模型），宿主 execve 直接替换子进程 */
static long sys_execve(const char *path, char *const argv[], char *const envp[]) {
    execve(path, argv, envp);   /* 成功不返回；失败返回 */
    return -errno;
}
static long sys_setpriority(int which, int who, int prio) {
    if (setpriority(which, who, prio)) return -errno;
    return 0;
}
static long sys_sched_getaffinity(pid_t pid, size_t size, void *mask) {
#ifdef __APPLE__
    (void)pid; (void)size; (void)mask;
    return -ENOSYS;   /* Darwin 无 sched_getaffinity（busybox taskset 仅 Linux） */
#else
    if (sched_getaffinity(pid, size, (cpu_set_t *)mask)) return -errno;
    return 0;
#endif
}
static long sys_sched_setaffinity(pid_t pid, size_t size, const void *mask) {
#ifdef __APPLE__
    (void)pid; (void)size; (void)mask;
    return -ENOSYS;
#else
    if (sched_setaffinity(pid, size, (const cpu_set_t *)mask)) return -errno;
    return 0;
#endif
}
static long sys_fstat(int fd, void *statbuf) {
    /* guest Linux stat 布局（aarch64）：st_dev..st_size..st_mtime..（与宿主 Linux x86_64 不同但 aarch64 宿主一致）；
       本地 Linux 宿主 x86_64 布局不同——用字段级转换保证正确性。 */
    struct linux_stat { uint64_t dev; uint64_t ino; uint32_t mode; uint32_t nlink; uint32_t uid; uint32_t gid;
                        uint64_t rdev; uint64_t size; uint64_t blksize; uint64_t blocks;
                        uint64_t atime; uint64_t atime_ns; uint64_t mtime; uint64_t mtime_ns;
                        uint64_t ctime; uint64_t ctime_ns; uint32_t unused[3]; };
    struct stat hs;
    if (fstat(fd, &hs)) return -errno;
    struct linux_stat *g = (struct linux_stat *)statbuf;
    memset(g, 0, sizeof(*g));
    g->dev = hs.st_dev; g->ino = hs.st_ino;
    g->mode = hs.st_mode; g->nlink = hs.st_nlink;
    g->uid = hs.st_uid; g->gid = hs.st_gid;
    g->rdev = hs.st_rdev; g->size = hs.st_size;
    g->blksize = hs.st_blksize; g->blocks = hs.st_blocks;
#ifdef __APPLE__
    g->atime = hs.st_atimespec.tv_sec; g->atime_ns = hs.st_atimespec.tv_nsec;
    g->mtime = hs.st_mtimespec.tv_sec; g->mtime_ns = hs.st_mtimespec.tv_nsec;
    g->ctime = hs.st_ctimespec.tv_sec; g->ctime_ns = hs.st_ctimespec.tv_nsec;
#else
    g->atime = hs.st_atime; g->atime_ns = hs.st_atim.tv_nsec;
    g->mtime = hs.st_mtime; g->mtime_ns = hs.st_mtim.tv_nsec;
    g->ctime = hs.st_ctime; g->ctime_ns = hs.st_ctim.tv_nsec;
#endif
    return 0;
}
static long sys_wait4(pid_t pid, int *status, int options, void *rusage) {
    int st;
    pid_t w = wait4(pid, &st, options, (struct rusage *)rusage);
    if (w < 0) return -errno;
    if (status) *status = st;
    return (long)w;
}
static long sys_dup3(int oldfd, int newfd, int flags) {
    (void)flags;
    if (dup2(oldfd, newfd) < 0) return -errno;
    return newfd;
}
static long sys_uname(void *buf) {
    /* 填一个伪 Linux uname（busybox 常见查询） */
    struct { char sys[65], node[65], rel[65], ver[65], mach[65], dom[65]; } *u = buf;
    memset(u, 0, sizeof(*u));
    strcpy(u->sys, "Linux");
    strcpy(u->node, "trollagent");
    strcpy(u->rel, "5.15.0");
    strcpy(u->ver, "#1 SMP");
    strcpy(u->mach, "aarch64");
    strcpy(u->dom, "(none)");
    return 0;
}

static uint64_t g_heap_base = 0, g_heap_cur = 0, g_heap_top = 0;
static uint64_t g_stack_base = 0;   /* v10: 栈区记录（MAP_FIXED 重叠判断用） */
uint64_t g_580_redirect = 0;       /* v19.12: guest 0x580000 写缓冲区重定向基址 */
static long sys_brk(uintptr_t newbrk) {
    if (getenv("BRK_TRACE")) fprintf(stderr, "[brk] newbrk=%lx\n", (unsigned long)newbrk);
    /* musl malloc 依赖 brk 扩展堆：brk(0) 返回当前堆顶；brk(nb) 成功返回 nb、失败返回旧堆顶 */
    if (g_heap_base == 0) {
        void *h = mmap(NULL, 16 << 20, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON, -1, 0);
        if (h == MAP_FAILED) return -ENOMEM;
        fprintf(stderr, "[elf-runner] heap base=0x%lx size=16MB (g_base=0x%lx diff=0x%lx)\n",
                (unsigned long)h, (unsigned long)g_base, (unsigned long)((uintptr_t)h - g_base));
        g_heap_base = (uintptr_t)h;
        g_heap_cur = g_heap_base;
        g_heap_top = g_heap_base + (16 << 20);
    }
    if (newbrk == 0) return (long)g_heap_cur;
    if (newbrk > g_heap_top || newbrk < g_heap_base) return (long)g_heap_cur;
    g_heap_cur = newbrk;
    return (long)g_heap_cur;
}
static long sys_mmap(uintptr_t addr, size_t len, int prot, int flags, int fd, off_t off) {
    /* MAP_FIXED 支持；PROT_* 映射 iOS 相同 */
    int mprot = 0;
    if (prot & 1) mprot |= PROT_READ;
    if (prot & 2) mprot |= PROT_WRITE;
    if (prot & 4) mprot |= PROT_EXEC;
    /* ★ 根因修复（真机 EBADF=-9）：guest 是 Linux musl，MAP_ANONYMOUS 在 Linux=0x20，
       iOS 的 MAP_ANON=0x1000 —— 两平台常量不同，iOS 不识别 0x20 为匿名 → EBADF。
       v19.4：条件编译——Darwin 宿主翻译 0x20→0x1000；Linux 宿主(本地 harness)保留 0x20。
       匿名时 fd 强制 -1（两平台一致）。 */
    if (flags & 0x20) {
        fd = -1;
#ifdef __APPLE__
        flags = (flags & ~0x20) | 0x1000;
#endif
    }
    if (flags & 0x1000) fd = -1;
    /* ★ v10 根因修复（真机 EINVAL=-22）：musl mallocng 用 MAP_FIXED 固定映射到
       已映射区域（典型=sys_brk 堆基址 0x12c002000）。Linux 语义 MAP_FIXED 覆盖已有
       映射并成功；iOS(Darwin) 对已映射地址的 MAP_FIXED 返回 EINVAL → malloc 失败 →
       后续访问该页 SIGBUS(far=0x12c003000)。
       修复：MAP_FIXED 目标落在已知已映射区（ELF 加载区 / brk 堆 / 栈）→ 直接返回
       addr 视为成功（页已真实存在，guest 可直接读写）。 */
    if ((flags & 0x10) && addr != 0) {
        int in_mapped = 0;
        if (g_heap_base && addr >= g_heap_base && addr < g_heap_top)
            in_mapped = 1;
        else if (g_base && addr >= g_base && addr < g_base + g_total_size)
            in_mapped = 1;
        else if (g_stack_base && addr >= g_stack_base &&
                 addr < g_stack_base + (32 << 20))
            in_mapped = 1;
        if (in_mapped) {
            fprintf(stderr, "[elf-runner] v10 MAP_FIXED 命中已映射区 addr=0x%lx len=%zu prot=%d flags=0x%x -> 返回 addr\n",
                    (unsigned long)addr, len, prot, flags);
            return (long)addr;
        }
    }
    void *r = mmap((void*)addr, len, mprot, flags, fd, off);
    if (getenv("MAP_TRACE") && r != MAP_FAILED)
        fprintf(stderr, "[map] mmap -> 0x%lx len=%zu prot=%d flags=0x%x\n",
                (unsigned long)r, len, prot, flags);
    if (r == MAP_FAILED) {
        /* v10: MAP_FIXED 仍失败（与未知映射冲突）→ 去 FIXED 重试（musl 同款 fallback） */
        if ((flags & 0x10) && addr != 0) {
            fprintf(stderr, "[elf-runner] v10 MAP_FIXED 失败(%s) addr=0x%lx len=%zu -> 去 FIXED 重试\n",
                    strerror(errno), (unsigned long)addr, len);
            r = mmap(NULL, len, mprot, flags & ~0x10, fd, off);
            if (r != MAP_FAILED) return (long)(uintptr_t)r;
        }
        return -errno;
    }
    return (long)(uintptr_t)r;
}
static long sys_munmap(uintptr_t addr, size_t len) {
    if (munmap((void*)addr, len) != 0) return -errno;
    return 0;
}
static long sys_nanosleep(const struct timespec *req, struct timespec *rem) {
    struct timespec r = *req;
    /* 兼容非规范 timespec（guest usleep 余数链在 emu 下可能产生 nsec>=1e9）：进位归一化 */
    if (r.tv_nsec >= 1000000000L) {
        r.tv_sec += r.tv_nsec / 1000000000L;
        r.tv_nsec %= 1000000000L;
    }
    return (long)nanosleep(&r, rem);
}
static long sys_gettimeofday(void *tv, void *tz) {
    (void)tz;
    struct timeval *t = tv;
    gettimeofday(t, NULL);
    return 0;
}
static long sys_clock_gettime(int clk, void *ts) {
    (void)clk;
    struct timespec *t = ts;
    clock_gettime(CLOCK_REALTIME, t);
    return 0;
}

/* statfs/fstatfs：iOS(Darwin) struct statfs 布局 ≠ Linux——必须字段级转换，memcpy 会让
   guest 读到错位字段（f_bsize→f_blocks 低位、f_frsize→fstypename 字符）→ df 数据垃圾 → vfprintf null → SIGSEGV。
   Linux statfs 布局：type(0) bsize(8) blocks(16) bfree(24) bavail(32) files(40) ffree(48) fsid(56) namelen(64) frsize(72) flags(80) spare(88) */
struct linux_statfs {
    long f_type;            /* 0  */
    long f_bsize;           /* 8  */
    uint64_t f_blocks;      /* 16 */
    uint64_t f_bfree;       /* 24 */
    uint64_t f_bavail;      /* 32 */
    uint64_t f_files;       /* 40 */
    uint64_t f_ffree;       /* 48 */
    long f_fsid[2];         /* 56 */
    long f_namelen;         /* 64 */
    long f_frsize;          /* 72 */
    long f_flags;           /* 80 */
    long f_spare[4];        /* 88 */
};
static void statfs_to_linux(struct statfs *s, struct linux_statfs *ls) {
    memset(ls, 0, sizeof(*ls));
    ls->f_type = (long)s->f_type;
    ls->f_bsize = (long)s->f_bsize;
    ls->f_blocks = (uint64_t)s->f_blocks;
    ls->f_bfree = (uint64_t)s->f_bfree;
    ls->f_bavail = (uint64_t)s->f_bavail;
    ls->f_files = (uint64_t)s->f_files;
    ls->f_ffree = (uint64_t)s->f_ffree;
#ifdef __APPLE__
    ls->f_fsid[0] = (long)s->f_fsid.val[0];
    ls->f_fsid[1] = (long)s->f_fsid.val[1];
#else
    ls->f_fsid[0] = (long)s->f_fsid.__val[0];   /* glibc __fsid_t { int __val[2]; } */
    ls->f_fsid[1] = (long)s->f_fsid.__val[1];
#endif
    ls->f_flags = (long)s->f_flags;
    ls->f_namelen = 255;
    ls->f_frsize = (long)s->f_bsize;
}
static long sys_statfs(const char *path, void *buf) {
    struct statfs s;
    long r = (long)statfs(path, &s);
    if (r == 0) statfs_to_linux(&s, (struct linux_statfs *)buf);
    return r;
}
static long sys_fstatfs(int fd, void *buf) {
    struct statfs s;
    long r = (long)fstatfs(fd, &s);
    if (r == 0) statfs_to_linux(&s, (struct linux_statfs *)buf);
    return r;
}

/* getgroups：直接透传（guest/host gid_t 同为 4 字节） */
static long sys_getgroups(int size, gid_t *list) {
    return (long)getgroups(size, list);
}
/* sysinfo（arm64 nr 179）：ps 需要 uptime/loads/mem。
 * arm64 Linux struct sysinfo = LP64 128B 布局；iOS SDK 无此类型，手工定义（不依赖宿主头）。
 * Darwin 无 sysinfo()，用 sysctl/getloadavg 手工填充。 */
struct linux_sysinfo {
    long uptime;                 /* 0   */
    unsigned long loads[3];      /* 8   */
    unsigned long totalram;      /* 32  */
    unsigned long freeram;       /* 40  */
    unsigned long sharedram;     /* 48  */
    unsigned long bufferram;     /* 56  */
    unsigned long totalswap;     /* 64  */
    unsigned long freeswap;      /* 72  */
    unsigned short procs;        /* 80  */
    unsigned short pad;          /* 82  */
    unsigned long totalhigh;     /* 88  */
    unsigned long freehigh;      /* 96  */
    unsigned int mem_unit;       /* 104 */
    char _f[20 - 2*sizeof(long) - sizeof(unsigned int)]; /* 108 */
};
static long sys_sysinfo(void *buf) {
    struct linux_sysinfo si;
    memset(&si, 0, sizeof(si));
#if defined(__APPLE__)
    {
        struct timeval boot, now;
        size_t len = sizeof(boot);
        int mib[2] = { CTL_KERN, KERN_BOOTTIME };
        if (sysctl(mib, 2, &boot, &len, NULL, 0) == 0) {
            gettimeofday(&now, NULL);
            si.uptime = (long)(now.tv_sec - boot.tv_sec);
        }
        double load[3];
        if (getloadavg(load, 3) == 3) {
            si.loads[0] = (unsigned long)(load[0] * 65536.0);
            si.loads[1] = (unsigned long)(load[1] * 65536.0);
            si.loads[2] = (unsigned long)(load[2] * 65536.0);
        }
        uint64_t memsize = 0;
        len = sizeof(memsize);
        int mib2[2] = { CTL_HW, HW_MEMSIZE };
        if (sysctl(mib2, 2, &memsize, &len, NULL, 0) == 0) {
            si.totalram = (unsigned long)memsize;
            si.freeram = (unsigned long)memsize;
        }
        si.mem_unit = 1;
    }
#else
    {
        struct sysinfo si0;
        if (sysinfo(&si0) < 0) return -1;
        si.uptime = si0.uptime;
        memcpy(si.loads, si0.loads, sizeof(si.loads));
        si.totalram = si0.totalram;
        si.freeram = si0.freeram;
        si.sharedram = si0.sharedram;
        si.bufferram = si0.bufferram;
        si.totalswap = si0.totalswap;
        si.freeswap = si0.freeswap;
        si.procs = si0.procs;
        si.totalhigh = si0.totalhigh;
        si.freehigh = si0.freehigh;
        si.mem_unit = si0.mem_unit;
    }
#endif
    memcpy(buf, &si, sizeof(si));
    return 0;
}
/* sendfile（arm64 nr 71）：busybox cp 大文件加速路径。
 * Linux/BSD 的 sendfile 签名不同，统一用 read/write 循环实现（双平台可编译、语义正确）。
 * offset 为 guest off_t*（可空）；返回实际复制字节数。 */
static long sys_sendfile(int out_fd, int in_fd, off_t *offset, size_t count) {
    char buf[65536];
    off_t pos = offset ? *offset : 0;
    if (offset && lseek(in_fd, pos, SEEK_SET) < 0) return -errno;
    size_t total = 0;
    for (;;) {
        size_t want = sizeof(buf);
        if (count != 0 && count - total < want) want = count - total;
        ssize_t n = read(in_fd, buf, want);
        if (n < 0) return -errno;
        if (n == 0) break;
        size_t offw = 0;
        while (offw < (size_t)n) {
            ssize_t w = write(out_fd, buf + offw, (size_t)n - offw);
            if (w < 0) return -errno;
            offw += (size_t)w;
        }
        total += (size_t)n;
        if (count != 0 && total >= count) break;
    }
    if (offset) *offset = pos + (off_t)total;
    return (long)total;
}
/* fcntl 简化（busybox 常用 F_GETFL/F_SETFL 等） */
static long sys_fcntl(int fd, int cmd, long arg) {
    return (long)fcntl(fd, cmd, arg);
}
/* ioctl 简化（busybox 常用 TIOCGWINSZ 等） */
static long sys_ioctl(int fd, unsigned long req, long arg) {
    return (long)ioctl(fd, req, arg);
}

/* v19.18j: guest /lib 路径 → 宿主映射（ELF_LIB_PATH env）。
   ld-musl 按 guest 路径找 libc.so（/lib/libc.musl-aarch64.so.1），
   真机/本地测试把 Alpine lib 目录挂到 ELF_LIB_PATH。 */
static const char *guest_path_map(const char *p) {
    const char *lib = getenv("ELF_LIB_PATH");
    if (lib && *lib && p && strncmp(p, "/lib/", 5) == 0) {
        static __thread char buf[512];
        snprintf(buf, sizeof(buf), "%s/%s", lib, p + 5);
        return buf;
    }
    return p;
}

/* 主翻译入口：Linux syscall 号 → 本地实现
 * EMU_SYSCALL=1 时打印每个 syscall 的 nr/args/ret（v14 诊断）。 */
long translate_syscall(uint64_t nr,
                              uint64_t a0, uint64_t a1, uint64_t a2,
                              uint64_t a3, uint64_t a4, uint64_t a5) {
    long r;
    if (getenv("EMU_TRACE")) {
        fprintf(stderr, "[trace] nr=%llu a0=%llx a1=%llx a2=%llx a3=%llx\n",
                (unsigned long long)nr, (unsigned long long)a0,
                (unsigned long long)a1, (unsigned long long)a2, (unsigned long long)a3);
    }
    switch (nr) {
    case SYS_openat: {
        const char *p = guest_path_map((const char*)(uintptr_t)a1);
        if (is_proc_path(p)) r = vproc_open(p, (int)a2);
        else r = sys_openat((int)a0, p, (int)a2, (mode_t)a3);
        break;
    }
    case SYS_newfstatat:
        r = sys_newfstatat((int)a0, guest_path_map((const char*)(uintptr_t)a1), (struct linux_stat*)(uintptr_t)a2, (int)a3);        break;
    case SYS_getdents64:
        if ((int)a0 >= VPROC_BASE) r = vproc_getdents((int)a0, (void*)(uintptr_t)a1, (size_t)a2);
        else r = sys_getdents64((int)a0, (void*)(uintptr_t)a1, (size_t)a2);
        break;
    case SYS_writev:
        r = sys_writev((int)a0, (const struct iovec*)(uintptr_t)a1, (int)a2);        break;
    case 65:  /* arm64 readv */
        r = sys_readv((int)a0, (const struct iovec*)(uintptr_t)a1, (int)a2);        break;
    case SYS_close:
        if ((int)a0 >= VPROC_BASE) r = vproc_close((int)a0);
        else r = sys_close((int)a0);
        break;
    case SYS_exit:        r = sys_exit((int)a0); break;
    case SYS_exit_group:
        if (getenv("EXIT_TRACE")) fprintf(stderr, "[exit] code=%d\n", (int)a0);
        r = sys_exit_group((int)a0); break;
    case SYS_getpid:      r = sys_getpid(); break;
    case SYS_getppid:     r = sys_getppid(); break;
    case SYS_getuid:      r = sys_getuid(); break;
    case SYS_geteuid:     r = sys_geteuid(); break;
    case SYS_getgid:      r = sys_getgid(); break;
    case SYS_getegid:     r = sys_getegid(); break;
    case SYS_getcwd:      r = sys_getcwd((char*)(uintptr_t)a0, (size_t)a1); break;
    case SYS_umask:       r = sys_umask((mode_t)a0); break;
    case SYS_mkdirat:     r = sys_mkdirat((int)a0, (const char*)(uintptr_t)a1, (mode_t)a2); break;
    case SYS_unlinkat:    r = sys_unlinkat((int)a0, (const char*)(uintptr_t)a1, (int)a2); break;
    case SYS_renameat:    r = sys_renameat((int)a0, (const char*)(uintptr_t)a1, (int)a2, (const char*)(uintptr_t)a3); break;
    case SYS_renameat2:   r = sys_renameat2((int)a0, (const char*)(uintptr_t)a1, (int)a2, (const char*)(uintptr_t)a3, (unsigned)a4); break;
    case SYS_symlinkat:   r = sys_symlinkat((const char*)(uintptr_t)a0, (int)a1, (const char*)(uintptr_t)a2); break;
    case SYS_linkat:      r = sys_linkat((int)a0, (const char*)(uintptr_t)a1, (int)a2, (const char*)(uintptr_t)a3, (unsigned)a4); break;
    case SYS_fchmodat:    r = sys_fchmodat((int)a0, (const char*)(uintptr_t)a1, (mode_t)a2); break;
    case SYS_fchownat:    r = sys_fchownat((int)a0, (const char*)(uintptr_t)a1, (uid_t)a2, (gid_t)a3, (int)a4); break;
    case SYS_truncate:    r = sys_truncate((const char*)(uintptr_t)a0, (off_t)a1); break;
    case SYS_ftruncate:   r = sys_ftruncate((int)a0, (off_t)a1); break;
    case SYS_utimensat:   r = sys_utimensat((int)a0, (const char*)(uintptr_t)a1, (const struct timespec*)(uintptr_t)a2, (int)a3); break;
    case SYS_readlinkat: {                                    /* 本地回归发现：readlink 缺失——guest readlink ln 返回 1 */
        char *rbuf = malloc((size_t)a3 + 1);
        if (!rbuf) { r = -ENOMEM; break; }
        ssize_t n = readlinkat((int)a0, (const char*)(uintptr_t)a1, rbuf, (size_t)a3);
        if (n < 0) { r = -errno; }
        else { rbuf[n] = 0; memcpy((void*)(uintptr_t)a2, rbuf, (size_t)n + 1); r = n; }
        free(rbuf);
        break;
    }
    case SYS_write:       r = sys_write((int)a0, (void*)(uintptr_t)a1, (size_t)a2); break;
    case SYS_read:
        if ((int)a0 >= VPROC_BASE) r = vproc_read((int)a0, (void*)(uintptr_t)a1, (size_t)a2);
        else r = sys_read((int)a0, (void*)(uintptr_t)a1, (size_t)a2);
        break;
    case SYS_lseek:
        if ((int)a0 >= VPROC_BASE) r = vproc_lseek((int)a0, (off_t)a1, (int)a2);
        else r = sys_lseek((int)a0, (off_t)a1, (int)a2);
        break;
    case SYS_faccessat:   r = sys_faccessat((int)a0, (const char*)(uintptr_t)a1, (int)a2); break;
    case SYS_dup:         r = sys_dup((int)a0); break;
    case SYS_chdir:       r = sys_chdir((const char*)(uintptr_t)a0); break;
    case SYS_fork: {      /* httpd 每连接 fork：宿主 fork，父子各自继续解释器（fork 语义天然成立） */
        pid_t pid = fork();
        if (pid < 0) r = -errno; else r = (long)pid;
        break;
    }
    case SYS_execve:      r = sys_execve((const char*)(uintptr_t)a0, (char* const*)(uintptr_t)a1, (char* const*)(uintptr_t)a2); break;
    case SYS_setpriority: r = sys_setpriority((int)a0, (int)a1, (int)a2); break;
    case SYS_sched_getaffinity: r = sys_sched_getaffinity((pid_t)a0, (size_t)a1, (void*)(uintptr_t)a2); break;
    case SYS_sched_setaffinity: r = sys_sched_setaffinity((pid_t)a0, (size_t)a1, (const void*)(uintptr_t)a2); break;
    case SYS_fstat:       r = sys_fstat((int)a0, (void*)(uintptr_t)a1); break;
    case SYS_pipe2: {     /* tar -czf 调 gzip 子进程的管道 */
        int p[2];
#ifdef __APPLE__
        int fl = (int)a1;
        if (pipe(p)) r = -errno;
        else {
            if (fl & 0x800) { /* O_CLOEXEC：Darwin 手动 fcntl */
                int fd = (p[0] < p[1]) ? p[1] : p[0];
                fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC);
            }
            ((int*)(uintptr_t)a0)[0] = p[0]; ((int*)(uintptr_t)a0)[1] = p[1]; r = 0;
        }
#else
        if (pipe2(p, (int)a1)) r = -errno;
        else { ((int*)(uintptr_t)a0)[0] = p[0]; ((int*)(uintptr_t)a0)[1] = p[1]; r = 0; }
#endif
        break;
    }
    case 260:             r = sys_wait4((pid_t)a0, (int*)(uintptr_t)a1, (int)a2, (void*)(uintptr_t)a3); break;  /* wait4：xargs 父进程回收 */
    case SYS_dup3:        r = sys_dup3((int)a0, (int)a1, (int)a2); break;
    case SYS_uname:       r = sys_uname((void*)(uintptr_t)a0); break;
    case 43:              r = sys_statfs((const char*)(uintptr_t)a0, (void*)(uintptr_t)a1); break;  /* arm64 statfs */
    case 44:              r = sys_fstatfs((int)a0, (void*)(uintptr_t)a1); break;  /* arm64 fstatfs */
    case SYS_brk:         r = sys_brk((uintptr_t)a0); break;
    case SYS_mmap:        r = sys_mmap((uintptr_t)a0, (size_t)a1, (int)a2, (int)a3, (int)a4, (off_t)a5); break;
    case SYS_munmap:      r = sys_munmap((uintptr_t)a0, (size_t)a1); break;
    case 226:             r = 0; break;   /* mprotect：musl malloc mmap(prot=0) 后设权限；RWX 直连下无需真改 */
    case SYS_nanosleep:   r = sys_nanosleep((const struct timespec*)(uintptr_t)a0, (struct timespec*)(uintptr_t)a1); break;
    case SYS_gettimeofday:r = sys_gettimeofday((void*)(uintptr_t)a0, (void*)(uintptr_t)a1); break;
    case SYS_clock_gettime:r = sys_clock_gettime((int)a0, (void*)(uintptr_t)a1); break;
    case SYS_fcntl:       r = sys_fcntl((int)a0, (int)a1, (long)a2); break;
    case SYS_ioctl:       r = sys_ioctl((int)a0, (unsigned long)a1, (long)a2); break;
    /* v19.18e：socket 族 */
    case SYS_socket:      r = sys_socket((int)a0, (int)a1, (int)a2); break;
    case SYS_socketpair:  r = sys_socketpair((int)a0, (int)a1, (int)a2, (int*)(uintptr_t)a3); break;
    case SYS_connect:     r = sys_connect((int)a0, (const void*)(uintptr_t)a1, (socklen_t)a2); break;
    case SYS_bind:        r = sys_bind((int)a0, (const void*)(uintptr_t)a1, (socklen_t)a2); break;
    case SYS_listen:      r = sys_listen((int)a0, (int)a1); break;
    case SYS_accept:      r = sys_accept((int)a0, (void*)(uintptr_t)a1, (socklen_t*)(uintptr_t)a2, 0); break;
    case SYS_accept4:     r = sys_accept((int)a0, (void*)(uintptr_t)a1, (socklen_t*)(uintptr_t)a2, (int)a3); break;
    case SYS_getsockname: r = sys_getsockname((int)a0, (void*)(uintptr_t)a1, (socklen_t*)(uintptr_t)a2); break;
    case SYS_getpeername: r = sys_getpeername((int)a0, (void*)(uintptr_t)a1, (socklen_t*)(uintptr_t)a2); break;
    case SYS_sendto:      r = sys_sendto((int)a0, (const void*)(uintptr_t)a1, (size_t)a2, (int)a3,
                                         (const void*)(uintptr_t)a4, (socklen_t)a5); break;
    case SYS_recvfrom:    r = sys_recvfrom((int)a0, (void*)(uintptr_t)a1, (size_t)a2, (int)a3,
                                           (void*)(uintptr_t)a4, (socklen_t*)(uintptr_t)a5); break;
    case SYS_setsockopt:  r = sys_setsockopt((int)a0, (int)a1, (int)a2, (const void*)(uintptr_t)a3, (socklen_t)a4); break;
    case SYS_getsockopt:  r = sys_getsockopt((int)a0, (int)a1, (int)a2, (void*)(uintptr_t)a3, (socklen_t*)(uintptr_t)a4); break;
    case SYS_shutdown:    r = sys_shutdown((int)a0, (int)a1); break;
    case SYS_sendmsg:     r = sys_sendmsg((int)a0, (const struct msghdr*)(uintptr_t)a1, (int)a2); break;
    case SYS_recvmsg:     r = sys_recvmsg((int)a0, (struct msghdr*)(uintptr_t)a1, (int)a2); break;
    case SYS_poll:        r = sys_poll((struct pollfd*)(uintptr_t)a0, (nfds_t)a1, (int)a2); break;
    case 158:             r = sys_getgroups((int)a0, (gid_t*)(uintptr_t)a1); break;  /* arm64 getgroups */
    case 179:             r = sys_sysinfo((void*)(uintptr_t)a0); break;  /* arm64 sysinfo：ps 需要 */
    case 71:              r = sys_sendfile((int)a0, (int)a1, (off_t*)(uintptr_t)a2, (size_t)a3); break;  /* arm64 sendfile：cp 大文件 */
    case 96:              r = 0; break;   /* getrlimit（结构保持 0，busybox 启动查询用） */
    case 73: {            /* ppoll——nc 等网络 applet 的 I/O 等待（原容错返回 0 导致 nc 假超时退出） */
        struct timespec ppts, *ppts_p = NULL;
        if (a2) { memcpy(&ppts, (const void*)(uintptr_t)a2, sizeof(ppts)); ppts_p = &ppts; }
#ifdef __APPLE__
        int prv = poll((struct pollfd*)(uintptr_t)a0, (nfds_t)a1, (ppts_p ? (int)(ppts_p->tv_sec * 1000 + ppts_p->tv_nsec / 1000000) : -1));
#else
        int prv = ppoll((struct pollfd*)(uintptr_t)a0, (nfds_t)a1, ppts_p, (const sigset_t*)(uintptr_t)a3);
#endif
        r = (prv < 0) ? -errno : (long)prv;
        break;
    }
    case 103:             r = 0; break;   /* setitimer（nc -w 超时用；不真正生效但流程继续） */
    case 134: {           /* rt_sigaction——guest handler 无法在宿主执行，no-op（httpd 初始化必调） */
        if (a2) {   /* 返回旧 action：sigsetsize=8 的调用点——只写 3 个 u64（handler/flags/restorer），防溢出 */
            struct { uint64_t handler; uint64_t flags; uint64_t restorer; } *g = (void*)(uintptr_t)a2;
            g->handler = 0; g->flags = 0; g->restorer = 0;
        }
        r = 0;   /* 不真正装信号（guest handler 不可执行）；musl sigaction wrapper 只读返回值 */
        break;
    }
    case 135:             r = 0; break;   /* rt_sigprocmask */
    case 144:             r = 0; break;   /* sched_yield 族 */
    case 146:             r = 0; break;
    default:
        fprintf(stderr, "[elf-runner] unsupported syscall %llu (x0=%llu x1=%llu x2=%llu)\n",
                (unsigned long long)nr,
                (unsigned long long)a0, (unsigned long long)a1, (unsigned long long)a2);
        r = -ENOSYS;
    }
    return r;
}

/* ---- SIGTRAP handler：截获 brk（原 svc #0）→ 翻译 syscall ---- */
static void trap_handler(int sig, siginfo_t *si, void *ucv) {
    (void)sig; (void)si;
    ucontext_t *ctx = (ucontext_t *)ucv;
#if defined(__aarch64__)
    uint64_t nr  = REG_SYSCALL;               /* x16 = syscall 号 */
    uint64_t a0  = REG_X(0), a1 = REG_X(1), a2 = REG_X(2);
    uint64_t a3  = REG_X(3), a4 = REG_X(4), a5 = REG_X(5);

    /* 跳过 brk 指令（PC 指向 brk；brk 是 4 字节，跳到下一条） */
    uintptr_t pc = REG_PC;
    REG_PC = pc + 4;

    long ret = translate_syscall(nr, a0, a1, a2, a3, a4, a5);
    REG_X(0) = (uint64_t)ret;                 /* x0 = 返回值（Linux 负 errno 语义） */
#else
    (void)ctx;
#endif
}

/* ---- 14c8: SIGBUS/SIGSEGV handler：抓崩溃点（PC/LR/SP/FAR）定位 ----
 * 14e1: 解释器模式下（emu 激活），ELF 的非法内存访问 → siglongjmp 回解释器
 * 报错退出（不杀主进程）；非解释器模式保持 _exit 原行为。 */
extern int emu_is_active(void);
extern jmp_buf *emu_jmp_buf(void);
static void crash_handler(int sig, siginfo_t *si, void *ucv) {
    if (emu_is_active()) {
        ucontext_t *ctx = (ucontext_t *)ucv;
#if defined(__aarch64__)
        fprintf(stderr, "[elf-runner] emu mem fault sig=%d pc=0x%llx far=0x%llx -> longjmp\n",
                sig,
                (unsigned long long)ctx->uc_mcontext->__ss.__pc,
                (unsigned long long)(si ? (uintptr_t)si->si_addr : 0));
#else
        fprintf(stderr, "[elf-runner] emu mem fault sig=%d -> longjmp (host pc=%p far=%p)\n",
                sig,
                (void *)(ctx ? ctx->uc_mcontext.gregs[REG_RIP] : 0),
                (void *)(si ? si->si_addr : 0));
        {
            uintptr_t rip = (uintptr_t)(ctx ? ctx->uc_mcontext.gregs[REG_RIP] : 0);
            unsigned char buf[32];
            ssize_t n = -1;
            /* 只读探针：可能仍 fault——用已知好地址对比打印 */
            if (rip > 0x1000) {
                volatile unsigned char *p = (volatile unsigned char *)rip;
                for (int k = 0; k < 24 && (uintptr_t)p < rip + 24; k++) {
                    buf[k] = p[k];
                }
                n = 24;
            }
            if (n > 0) {
                fprintf(stderr, "  rip_bytes:");
                for (int k = 0; k < n; k++) fprintf(stderr, " %02x", buf[k]);
                fprintf(stderr, "\n");
            } else {
                fprintf(stderr, "  rip_bytes: <unreadable>\n");
            }
        }
        if (ctx) {
            for (int gi = 0; gi < 23; gi++)
                fprintf(stderr, "  g[%d]=0x%llx\n", gi, (unsigned long long)ctx->uc_mcontext.gregs[gi]);
            uintptr_t sp = (uintptr_t)ctx->uc_mcontext.gregs[REG_RSP];
            fprintf(stderr, "  stack:");
            for (int k = 0; k < 8; k++) {
                uintptr_t v;
                if (!sigprocmask) {} /* noop */
                /* 直接读宿主栈（handler 同线程） */
                v = *(volatile uintptr_t *)(sp + k * 8);
                fprintf(stderr, " [%d]=0x%llx", k, (unsigned long long)v);
            }
            fprintf(stderr, "\n");
        }
#endif
        siglongjmp(*emu_jmp_buf(), 1);
    }
    ucontext_t *ctx = (ucontext_t *)ucv;
#if defined(__aarch64__)
    fprintf(stderr, "[elf-runner] CRASH sig=%d pc=0x%llx lr=0x%llx sp=0x%llx far=0x%llx\n",
            sig,
            (unsigned long long)ctx->uc_mcontext->__ss.__pc,
            (unsigned long long)ctx->uc_mcontext->__ss.__lr,
            (unsigned long long)ctx->uc_mcontext->__ss.__sp,
            (unsigned long long)(si ? (uintptr_t)si->si_addr : 0));
#else
    (void)ctx; (void)si;
    fprintf(stderr, "[elf-runner] CRASH sig=%d\n", sig);
#endif
    _exit(128 + sig);
}

/* ---- ELF 加载 ---- */
/* ---- 14c8: PIE(ET_DYN) 重定位(.rela.dyn, R_AARCH64_RELATIVE) ----
 * PIE 的 GOT/数据含"相对加载基址"的项，需 *(base+r_offset)=base+r_addend 填入，
 * 否则跳入 entry 访问 GOT 指向未映射区 → SIGBUS。musl 静态 PIE 仅 RELATIVE 类型。
 * 必须在 load_elf 内 raw(free 前)调用：section header 表可能在 LOAD 段外未加载到 g_base。 */
static int apply_relocations(const uint8_t *raw, const Elf64_Ehdr *eh, uintptr_t base) {
    if (!eh || eh->e_shoff == 0 || eh->e_shnum == 0 || eh->e_shstrndx >= eh->e_shnum) {
        fprintf(stderr, "[elf-runner] reloc: 无 section headers(ET_EXEC?) 跳过\n");
        return 0;
    }
    const Elf64_Shdr *sh = (const Elf64_Shdr *)(raw + eh->e_shoff);
    const char *shstr = (const char *)(raw + sh[eh->e_shstrndx].sh_offset);
    for (unsigned i = 0; i < eh->e_shnum; i++) {
        if (sh[i].sh_type != SHT_RELA) continue;
        const char *secname = shstr + sh[i].sh_name;
        const Elf64_Rela *rela = (const Elf64_Rela *)(raw + sh[i].sh_offset);
        size_t n = sh[i].sh_size / sizeof(Elf64_Rela);
        size_t done = 0, skipped = 0;
        for (size_t j = 0; j < n; j++) {
            uint64_t type = rela[j].r_info & 0xffffffffULL;
            if (type == R_AARCH64_RELATIVE) {
                uint64_t *p = (uint64_t *)(base + rela[j].r_offset);
                *p = base + (uint64_t)rela[j].r_addend;
                done++;
            } else {
                if (skipped < 5)
                    fprintf(stderr, "[elf-runner] reloc %s: 未处理 type=%llu off=0x%llx\n",
                            secname, (unsigned long long)type,
                            (unsigned long long)rela[j].r_offset);
                skipped++;
            }
        }
        fprintf(stderr, "[elf-runner] reloc %s: %zu entries, %zu RELATIVE applied, %zu skipped\n",
                secname, n, done, skipped);
    }
    return 0;
}

static int load_interp(const char *path, uintptr_t *ibase_out, uintptr_t *ientry_out); /* v19.18j 前置声明 */
static int load_elf(const char *path, uintptr_t *entry_out) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("elf-runner: open"); return -1; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < sizeof(Elf64_Ehdr)) { close(fd); return -1; }

    uint8_t *raw = malloc(st.st_size);
    if (!raw) { close(fd); return -1; }
    if (read(fd, raw, st.st_size) != st.st_size) { free(raw); close(fd); return -1; }
    close(fd);

    Elf64_Ehdr *eh = (Elf64_Ehdr *)raw;
    if (eh->magic != ELF_MAGIC || eh->ei_class != 2 || eh->e_machine != EM_AARCH64) {
        fprintf(stderr, "elf-runner: 不是 aarch64 ELF64（%s）\n", path);
        free(raw);
        return -1;
    }
    g_phoff = eh->e_phoff;
    g_phentsize = eh->e_phentsize;
    g_phnum = eh->e_phnum;

    /* 计算覆盖全部 PT_LOAD 的 [低 vaddr, 高 vaddr] */
    uintptr_t lo = UINTPTR_MAX, hi = 0;
    for (int i = 0; i < eh->e_phnum; i++) {
        Elf64_Phdr *ph = (Elf64_Phdr *)(raw + eh->e_phoff + i * eh->e_phentsize);
        if (ph->p_type != PT_LOAD) continue;
        uintptr_t vlo = ph->p_vaddr & ~(uintptr_t)4095;
        uintptr_t vhi = (ph->p_vaddr + ph->p_memsz + 4095) & ~(uintptr_t)4095;
        if (vlo < lo) lo = vlo;
        if (vhi > hi) hi = vhi;
    }
    if (lo == UINTPTR_MAX) { free(raw); return -1; }
    size_t total = hi - lo;
    /* 14c8: MAP_JIT 要求 size 页对齐——arm64 iOS 页 16KB(0x4000)，非对齐 mmap 报 EINVAL */
    total = (total + 0x3fff) & ~(size_t)0x3fff;
    g_load_vaddr = lo;
    g_total_size = total;

    /* 映射整块（MAP_FIXED 到 ELF 期望地址；低地址通常空闲）。
       14c8 MAP_JIT：iOS 16 执行 mmap 代码必须 MAP_JIT+dynamic-codesigning，
       否则 mprotect(RX) 后取指仍 SIGBUS（allow-unsigned-executable-memory 仅 macOS 有效）。
       iOS 禁止 MAP_JIT+MAP_FIXED（EINVAL）→ 首试固定地址仅用于诊断，正常走非固定。
       14d9: MAP_JIT 全部 EINVAL（无 JIT 激活）时 fallback——mmap(PROT_READ|PROT_WRITE|PROT_EXEC)
       一次性 RWX（allow-unsigned-executable-memory 的"create writable and executable memory"
       语义，不经过 MAP_JIT）。TrollStore App 带该 entitlement，iOS 16 若豁免 W^X 则无需 JIT。 */
    void *m = mmap((void *)lo, total, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON | MAP_JIT | MAP_FIXED, -1, 0);
    if (m == MAP_FAILED) {
        /* 地址冲突时退回任意地址并重定位（静态 ELF 假设固定地址，先试 MAP_FIXED） */
        fprintf(stderr, "elf-runner: mmap 0x%lx 失败 (%s)，尝试非固定 MAP_JIT\n",
                (unsigned long)lo, strerror(errno));
        m = mmap(NULL, total, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    }
    if (m == MAP_FAILED) {
        fprintf(stderr, "elf-runner: MAP_JIT 均失败 (%s)，尝试 RWX 直连(allow-unsigned)\n",
                strerror(errno));
        m = mmap(NULL, total, PROT_READ | PROT_WRITE | PROT_EXEC,
                 MAP_PRIVATE | MAP_ANON, -1, 0);
        if (m != MAP_FAILED) g_rwx = 1;
    }
    if (m == MAP_FAILED) {
        fprintf(stderr, "elf-runner: RWX mmap 失败 (%s) total=0x%zx\n",
                strerror(errno), total);
        free(raw); return -1;
    }
    if ((uintptr_t)m != lo) {
        fprintf(stderr, "[elf-runner] 非固定映射 base=0x%lx（原 vaddr 0x%lx）\n",
                (unsigned long)m, (unsigned long)lo);
    }
    g_base = (uintptr_t)m;   /* 实际映射基址：MAP_FIXED 成功=lo 原址；失败=任意地址 */
    fprintf(stderr, "[elf-runner] mmap: base=0x%lx g_load_vaddr=0x%lx total=%zu\n",
            (unsigned long)g_base, (unsigned long)g_load_vaddr, g_total_size);

    /* 拷贝段 + 记录段信息（先全部保持 RW 以便 patch_svc；patch 后统一 mprotect） */
    g_nsegs = 0;
    for (int i = 0; i < eh->e_phnum && g_nsegs < MAX_SEGS; i++) {
        Elf64_Phdr *ph = (Elf64_Phdr *)(raw + eh->e_phoff + i * eh->e_phentsize);
        if (ph->p_type != PT_LOAD) continue;
        uintptr_t dst = g_base + (ph->p_vaddr - g_load_vaddr);
        fprintf(stderr, "[elf-runner] seg#%d: vaddr=0x%lx rel_off=%zu filesz=%zu dst=0x%lx\n",
                g_nsegs, (unsigned long)ph->p_vaddr, (size_t)(dst - g_base),
                (size_t)ph->p_filesz, (unsigned long)dst);
        if (ph->p_filesz > 0)
            memcpy((void *)dst, raw + ph->p_offset, ph->p_filesz);
        int prot = 0;
        if (ph->p_flags & PF_R) prot |= PROT_READ;
        if (ph->p_flags & PF_W) prot |= PROT_WRITE;
        if (ph->p_flags & PF_X) prot |= PROT_EXEC;
        // 14c8 fix: mprotect 要求 addr 页对齐(4KB)。ELF 段 vaddr 可非页对齐(seg1 0x51d2d0)，
        // 直接 g_base+off 未对齐→mprotect EINVAL。段起止对齐到页供 mprotect(memcpy 仍用精确 dst)。
        uintptr_t seg_start = dst & ~(uintptr_t)4095;
        uintptr_t seg_end = (dst + ph->p_memsz + 4095) & ~(uintptr_t)4095;
        g_segs[g_nsegs].base = g_base;
        g_segs[g_nsegs].off = seg_start - g_base;
        g_segs[g_nsegs].len = seg_end - seg_start;
        g_segs[g_nsegs].prot = prot;
        g_nsegs++;
    }

    /* v19.18j: 检测 PT_INTERP（动态 ELF）→ 记录 interp 路径（guest 内路径，如 /lib/ld-musl-aarch64.so.1） */
    g_interp_name[0] = 0;
    for (int i = 0; i < eh->e_phnum; i++) {
        Elf64_Phdr *ph = (Elf64_Phdr *)(raw + eh->e_phoff + i * eh->e_phentsize);
        if (ph->p_type == PT_INTERP) {
            size_t n = ph->p_filesz;
            if (n >= sizeof(g_interp_name)) n = sizeof(g_interp_name) - 1;
            memcpy(g_interp_name, raw + ph->p_offset, n);
            g_interp_name[n] = 0;
            fprintf(stderr, "[elf-runner] PT_INTERP: %s\n", g_interp_name);
            break;
        }
    }

    /* 入口需加基址偏移（g_load_vaddr 为原始 vaddr；g_base 为实际映射基址） */
    *entry_out = g_base + (eh->e_entry - g_load_vaddr);
    fprintf(stderr, "[elf-runner] load done: entry=0x%lx\n", (unsigned long)*entry_out);

    /* 14c8: PIE 重定位(RELATIVE) 须在 free(raw) 前、段仍 RW 时执行 */
    if (apply_relocations(raw, eh, g_base) != 0) { free(raw); return -1; }

    free(raw);
    return 0;
}

/* v19.18j: 动态 ELF 检测——返回 interp 是否已加载（elf_runner_main 用）
   ELF_INTERP_PATH env 覆盖 interp 宿主路径（测试/真机部署用）。 */
static int load_dynamic_interp(void) {
    if (!g_interp_name[0]) return 0;
    const char *ip = getenv("ELF_INTERP_PATH");
    if (!ip || !*ip) ip = g_interp_name;
    fprintf(stderr, "[elf-runner] 动态 ELF：加载 interp %s\n", ip);
    uintptr_t i_base = 0, i_entry = 0;
    if (load_interp(ip, &i_base, &i_entry) != 0) return -1;
    return 1;
}

/* v19.18j: 加载动态链接器（ld-musl）到独立基址。
   与主程序同模式：mmap 整块 → copy PT_LOAD → 记录段 → RELATIVE reloc。
   interp 是 ET_DYN(static-pie 链接)，vaddr 从 0 起，映射到宿主任意地址（位置无关）。 */
static int load_interp(const char *path, uintptr_t *ibase_out, uintptr_t *ientry_out) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("elf-runner: interp open"); return -1; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < sizeof(Elf64_Ehdr)) { close(fd); return -1; }
    uint8_t *raw = malloc(st.st_size);
    if (!raw) { close(fd); return -1; }
    if (read(fd, raw, st.st_size) != st.st_size) { free(raw); close(fd); return -1; }
    close(fd);
    Elf64_Ehdr *eh = (Elf64_Ehdr *)raw;
    if (eh->magic != ELF_MAGIC || eh->ei_class != 2 || eh->e_machine != EM_AARCH64) {
        fprintf(stderr, "elf-runner: interp 不是 aarch64 ELF64（%s）\n", path);
        free(raw); return -1;
    }
    uintptr_t lo = UINTPTR_MAX, hi = 0;
    for (int i = 0; i < eh->e_phnum; i++) {
        Elf64_Phdr *ph = (Elf64_Phdr *)(raw + eh->e_phoff + i * eh->e_phentsize);
        if (ph->p_type != PT_LOAD) continue;
        uintptr_t vlo = ph->p_vaddr & ~(uintptr_t)4095;
        uintptr_t vhi = (ph->p_vaddr + ph->p_memsz + 4095) & ~(uintptr_t)4095;
        if (vlo < lo) lo = vlo;
        if (vhi > hi) hi = vhi;
    }
    if (lo == UINTPTR_MAX) { free(raw); return -1; }
    size_t total = hi - lo;
    total = (total + 0x3fff) & ~(size_t)0x3fff;
    void *m = mmap(NULL, total, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (m == MAP_FAILED) {
        m = mmap(NULL, total, PROT_READ | PROT_WRITE | PROT_EXEC,
                 MAP_PRIVATE | MAP_ANON, -1, 0);
        if (m != MAP_FAILED) g_rwx = 1;
    }
    if (m == MAP_FAILED) {
        fprintf(stderr, "elf-runner: interp mmap 失败 total=0x%zx (%s)\n", total, strerror(errno));
        free(raw); return -1;
    }
    uintptr_t ibase = (uintptr_t)m;
    for (int i = 0; i < eh->e_phnum && g_nsegs < MAX_SEGS; i++) {
        Elf64_Phdr *ph = (Elf64_Phdr *)(raw + eh->e_phoff + i * eh->e_phentsize);
        if (ph->p_type != PT_LOAD) continue;
        uintptr_t dst = ibase + (ph->p_vaddr - lo);
        fprintf(stderr, "[elf-runner] iseg#%d vaddr=0x%lx filesz=%zu dst=0x%lx\n",
                i, (unsigned long)ph->p_vaddr, (size_t)ph->p_filesz, (unsigned long)dst);
        if (ph->p_filesz > 0)
            memcpy((void *)dst, raw + ph->p_offset, ph->p_filesz);
        int prot = 0;
        if (ph->p_flags & PF_R) prot |= PROT_READ;
        if (ph->p_flags & PF_W) prot |= PROT_WRITE;
        if (ph->p_flags & PF_X) prot |= PROT_EXEC;
        uintptr_t seg_start = dst & ~(uintptr_t)4095;
        uintptr_t seg_end = (dst + ph->p_memsz + 4095) & ~(uintptr_t)4095;
        g_segs[g_nsegs].base = ibase;
        g_segs[g_nsegs].off = seg_start - ibase;
        g_segs[g_nsegs].len = seg_end - seg_start;
        g_segs[g_nsegs].prot = prot;
        g_nsegs++;
    }
    *ibase_out = ibase;
    *ientry_out = ibase + (eh->e_entry - lo);
    g_interp_base = ibase;
    g_interp_size = total;
    g_interp_entry = *ientry_out;
    fprintf(stderr, "[elf-runner] interp loaded: base=0x%lx total=%zu entry=0x%lx\n",
            (unsigned long)ibase, total, (unsigned long)*ientry_out);
    if (apply_relocations(raw, eh, ibase) != 0) { free(raw); return -1; }
    free(raw);
    return 0;
}

/* ---- patch: svc #0 → brk #1（在加载内存内扫描；此时段仍 RW） ---- */
static int patch_svc(void) {
    int patched = 0;
    for (int s = 0; s < g_nsegs; s++) {
        uintptr_t base = g_segs[s].base;
        size_t len = g_segs[s].len;
        fprintf(stderr, "[elf-runner] patch scan seg%d base=0x%lx len=%zu\n",
                s, (unsigned long)base, len);
        for (size_t off = 0; off + 4 <= len; off += 4) {
            uint32_t *insn = (uint32_t *)(base + off);
            if (*insn == SVC_0) {
                *insn = BRK_1;
                patched++;
            }
        }
    }
    fprintf(stderr, "[elf-runner] patch done: %d svc sites\n", patched);
    return patched;
}

/* ---- patch 完成后统一按段设保护 ---- */
static int apply_seg_prot(void) {
    if (g_rwx) {
        /* 14da: mmap 已 RWX 直连(allow-unsigned)——14d9 实测 mprotect 去 W 后取指仍 SIGBUS
           (iOS16 W^X: 执行检查拒绝从 RWX 历史页面收权后的 X)。
           保持 RWX 直接执行（allow-unsigned-executable-memory 语义=创建可写可执行内存）。 */
        fprintf(stderr, "[elf-runner] RWX 直连模式：保持可写可执行，跳过 mprotect\n");
        return 0;
    }
    for (int i = 0; i < g_nsegs; i++) {
        // 14c8: mmap 初始即 PROT_READ|PROT_WRITE，R|W 段已是目标权限→无需 mprotect。
        // (iOS 上对含未写入 gap 页的区域 mprotect R|W 实测 EINVAL——seg0 R|X 成功、seg1 R|W 失败)。
        // 只需对含 X(或去 W) 的段改权限。
        if (g_segs[i].prot == (PROT_READ | PROT_WRITE)) {
            fprintf(stderr, "[elf-runner] seg%d rw(初始即RW,跳过) off=0x%lx len=%zu\n",
                    i, (unsigned long)g_segs[i].off, g_segs[i].len);
            continue;
        }
        fprintf(stderr, "[elf-runner] mprotect seg%d off=0x%lx len=%zu prot=%d\n",
                i, (unsigned long)g_segs[i].off, g_segs[i].len, g_segs[i].prot);
        if (mprotect((void *)(g_segs[i].base + g_segs[i].off), g_segs[i].len, g_segs[i].prot) != 0) {
            perror("mprotect seg");
            return -1;
        }
    }
    return 0;
}

/* 14de: 检测当前进程是否已带 JIT（TrollStore attach 后 CS_DEBUGGED + dynamic-codesigning 生效，
   MAP_JIT 可成功）。成功=已有 JIT（勿再请求 URL 闪切）；失败=需懒激活。 */
int have_jit(void) {
    void *m = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (m != MAP_FAILED) {
        munmap(m, 0x4000);
        return 1;
    }
    return 0;
}

int elf_runner_main(int argc, char **argv) {
    /* 14dc: 主进程内跑模式——sigsetjmp 出口兜住 ELF 的 exit_group（sys_exit_group siglongjmp 回），
       主进程存活。spawn 模式(_exit 路径)不受影响（g_exit_jumped 置位后正常返回给调用方）。 */
    extern void emu_deactivate(void);
    if (sigsetjmp(g_exit_jmp, 1) != 0) {
        emu_deactivate();   /* 14e1: 解释器被 exit_group longjmp 中断，复位 crash 兜底状态 */
        /* v19.18c: guest 执行完释放本轮 mmap——App 是常驻 8790 服务，每次调用泄漏
           stack 32MB + ELF 1.3MB + 0x580000 区 128KB + heap 16MB，连续 277 条命令
           后内存耗尽（mmap Cannot allocate memory → App 假死/被杀）。 */
        if (g_stack_base) { munmap((void *)g_stack_base, 32 << 20); g_stack_base = 0; }
        if (g_heap_base)  { munmap((void *)g_heap_base, 16 << 20); g_heap_base = g_heap_cur = g_heap_top = 0; }
        if (g_interp_base) { munmap((void *)g_interp_base, g_interp_size); g_interp_base = 0; }
        if (g_base) {
            munmap((void *)(g_base + 0x580000), 0x20000);   /* guest 0x580000 写缓冲区（独立映射） */
            munmap((void *)g_base, g_total_size);
            g_base = 0;
        }
        fprintf(stderr, "[elf-runner] ELF 退出 code=%d（进程内模式，主进程存活）\n", g_exit_code);
        return g_exit_code;
    }
    g_exit_jumped = 1;

    if (argc < 2) {
        fprintf(stderr, "usage: elf-runner <linux-aarch64-static-elf> [args...]\n");
        return 2;
    }
    const char *elf_path = argv[1];
    fprintf(stderr, "[elf-runner] START argc=%d elf=%s (ELF-RUNNER 2026-10-21 v19.4 clean)\n", argc, elf_path);

    /* 14e0: 诊断进程实际 csflags（CS_DEBUGGED=0x800）——TrollStore 手动 JIT 启动/URL 激活后
       到底有没有被 attach。csops(CS_OPS_STATUS) 是唯一可靠的运行时查询。 */
    extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define CS_OPS_STATUS 0
#define CS_DEBUGGED  0x800
    {
        unsigned int csflags = 0;
        if (csops(getpid(), CS_OPS_STATUS, &csflags, sizeof(csflags)) == 0) {
            fprintf(stderr, "[elf-runner] csflags=0x%x debugged=%d allow-jit-check=%d\n",
                    csflags, (csflags & CS_DEBUGGED) != 0, (csflags & 0x4000000) != 0);
        } else {
            fprintf(stderr, "[elf-runner] csops failed: %s\n", strerror(errno));
        }
    }

    /* 14d7: JIT 激活由本进程外部完成（TrollStore 手动"以 JIT 启动"或 apple-magnifier URL，
       进程内带 CS_DEBUGGED 进入）。单进程直跑——14d0-14d2 的 fork 方案已实证死路：
       iOS16 App fork 子进程必被 SIGBUS 杀（st=0xa 三版复现，pre-stop 日志未出）。 */
    uintptr_t entry = 0;
    if (load_elf(elf_path, &entry) != 0) return 1;
    g_app_entry = entry;   /* 主程序 entry（AT_ENTRY 应指向它，musl CRTJMP 用） */

    /* v19.18j: 动态 ELF → entry 指向 ld-musl（动态解析由 guest 内 ld-musl 完成） */
    int dyn = load_dynamic_interp();
    if (dyn < 0) return 3;
    if (dyn > 0) entry = g_interp_entry;

    /* 14e1: 解释器模式（用户选 A）——不再 patch_svc / apply_seg_prot / jump 直跑。
       iOS16.3+TrollStore 无 MAP_JIT 可用（csflags 实测 debugged=0、allow-jit 位不在），
       可执行内存取指必 SIGBUS。解释器把指令当数据处理逐条解码，svc 指令
       在 emu 内直接走 translate_syscall。ELF 段保持 RW。 */

        /* 注册 SIGBUS/SIGSEGV handler：解释器模式下非法内存访问 longjmp 回 emu
           （不杀主进程）；非解释器模式保留崩溃定位。 */
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = crash_handler;
        sa.sa_flags = SA_SIGINFO;
        sigaction(SIGBUS, &sa, NULL);
        sigaction(SIGSEGV, &sa, NULL);

    /* v19.12: musl/busybox .data 硬编码写缓冲指针 0x580000（stdout 等写缓冲）。
       原始链接布局预期 guest 0x580000 区存在，ELF 段只映射到 0x140000 → ps
       写缓冲 SIGSEGV。优先 MAP_FIXED_NOREPLACE 直接映射；宿主占用时改用 emu
       访存层透明重定向（g_580_redirect）——不覆盖宿主、不改 guest 数据。 */
    g_580_redirect = 0;
    {
        int mf = MAP_FIXED;
#ifdef MAP_FIXED_NOREPLACE
        mf = MAP_FIXED_NOREPLACE;
#endif
        void *fb = mmap((void *)(g_base + 0x580000), 0x20000,
                        PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANON | mf, -1, 0);
        if (fb != MAP_FAILED) {
            fprintf(stderr, "[elf-runner] guest 0x580000 区直接映射成功 @ host 0x%lx (128KB)\n",
                    (unsigned long)(g_base + 0x580000));
        } else {
            /* 宿主占用：MAP_FIXED 覆盖（ps 主路径全通已验证），宿主退出清理由
               harness _exit 跳过（不跑 libc atexit/清理，避免访问被覆盖区）。 */
            fb = mmap((void *)(g_base + 0x580000), 0x20000,
                      PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
            fprintf(stderr, "[elf-runner] guest 0x580000 区被宿主占用（errno=%d）→ MAP_FIXED 覆盖 %s @ 0x%lx\n",
                    errno, fb == MAP_FAILED ? "失败" : "成功",
                    (unsigned long)(g_base + 0x580000));
        }
    }

    /* 布置 Linux 初始栈（aarch64 Linux ABI）：
       sp→[argc][argv[0..n-1]][NULL][envp NULL][auxv: AT_* 对][AT_NULL]
       musl/glibc _start 从 [sp] 读 argc，argv=sp+8；auxv 需完整
       (AT_PHDR/AT_PHENT/AT_PHNUM/AT_PAGESZ/AT_ENTRY/AT_RANDOM 等)，
       缺 AT_PHDR/AT_RANDOM 时 musl 静态 PIE 启动路径会读错 → SIGBUS。 */
    /* 布局结论（本地 v1 复现链：指针表 sp_top-4096 + 字符串 guest(sp_top-512) + 标准 auxv = hello；
       指针表 -512 → applet not found；auxv 写入必须从 0 索引（曾用 a=narg+3 起写错位→reloc 崩）。 */
    int narg = argc - 1;
    uint8_t *stack = mmap(NULL, 32 << 20, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANON, -1, 0);
    if (stack == MAP_FAILED) { perror("stack"); return 1; }
    g_stack_base = (uintptr_t)stack;   /* v10: 记录栈区（MAP_FIXED 重叠判断用） */
    uintptr_t sp_top = ((uintptr_t)stack + (32 << 20)) & ~15ULL;
    char *p = (char *)(sp_top - 512);               /* 字符串区（与本地跑通配置一致） */
    uintptr_t *argstr = (uintptr_t *)malloc((narg + 2) * sizeof(uintptr_t));
    int i;
    for (i = 0; i < narg; i++) {
        size_t l = strlen(argv[i + 1]) + 1;
        memcpy(p, argv[i + 1], l);
        argstr[i] = (uintptr_t)p;
        p += l;
    }
    uintptr_t plat = (uintptr_t)p; memcpy(p, "aarch64", 8); p += 8;   /* AT_PLATFORM */
    uintptr_t rndp  = (uintptr_t)p; memset(p, 0xAB, 16); p += 16;     /* AT_RANDOM(16B) */
    uintptr_t *slot = (uintptr_t *)(((uintptr_t)(sp_top - 4096) + 15) & ~15ULL); /* 指针表 */
    int a = 0;
    slot[a++] = (uintptr_t)narg;                  /* argc */
    for (i = 0; i < narg; i++) slot[a++] = argstr[i];   /* argv[] */
    slot[a++] = 0;                                /* argv 终止 */
    /* v19.18d：guest 环境（PATH/HOME）——printenv/env 可用 */
    {
        const char *env_def[] = { "PATH=/sbin:/usr/sbin:/bin:/usr/bin",
                                  "HOME=/var/mobile" };
        uintptr_t envstr[8];
        int ne = 0;
        for (i = 0; i < 2; i++) {
            size_t l = strlen(env_def[i]) + 1;
            if ((uintptr_t)(p - l) < (sp_top - 4096)) break;  /* 防溢出字符串区 */
            memcpy(p, env_def[i], l);
            envstr[ne++] = (uintptr_t)p;
            p += l;
        }
        slot[a++] = envstr[0];
        slot[a++] = envstr[1];
        slot[a++] = 0;                            /* envp 终止 */
    }
    /* v19.18j 修复：a 已在 envp NULL（slot[a-1]）写入后自增——slot[a] 就是
       auxv 起点。实测 &slot[a+1] 会让 slot[a] 残留 0，musl 把 0 当 AT_NULL
       → auxv 全空 → AT_BASE=0 → RELATIVE 处理崩。 */
    uint64_t *aux = (uint64_t *)&slot[a];         /* auxv（envp NULL 之后） */
    int aa = 0;
    aux[aa++] = 3;  aux[aa++] = g_base + g_phoff; /* AT_PHDR */
    aux[aa++] = 4;  aux[aa++] = g_phentsize;        /* AT_PHENT */
    aux[aa++] = 5;  aux[aa++] = g_phnum;            /* AT_PHNUM */
    aux[aa++] = 6;  aux[aa++] = 4096;               /* AT_PAGESZ */
    aux[aa++] = 7;  aux[aa++] = g_interp_base;         /* AT_BASE（动态=interp 基址；静态=0） */
    aux[aa++] = 8;  aux[aa++] = 0;                  /* AT_FLAGS */
    aux[aa++] = 9;  aux[aa++] = g_app_entry;        /* AT_ENTRY=主程序 entry（musl CRTJMP 跳它；不能用 interp entry） */
    aux[aa++] = 11; aux[aa++] = 0;                  /* AT_UID */
    aux[aa++] = 12; aux[aa++] = 0;                  /* AT_EUID */
    aux[aa++] = 13; aux[aa++] = 0;                  /* AT_GID */
    aux[aa++] = 14; aux[aa++] = 0;                  /* AT_EGID */
    aux[aa++] = 17; aux[aa++] = 100;                /* AT_CLKTCK */
    aux[aa++] = 23; aux[aa++] = 0;                  /* AT_SECURE */
    aux[aa++] = 25; aux[aa++] = rndp;               /* AT_RANDOM */
    aux[aa++] = 16; aux[aa++] = 0;                  /* AT_HWCAP */
    aux[aa++] = 31; aux[aa++] = argstr[0];          /* AT_EXECFN */
    aux[aa++] = 15; aux[aa++] = plat;               /* AT_PLATFORM */
    aux[aa++] = 26; aux[aa++] = 0;                  /* AT_HWCAP2 */
    aux[aa++] = 0;                                 /* AT_NULL */

    fprintf(stderr, "[elf-runner] loading %s entry=0x%lx base=0x%lx size=%zu\n",
            elf_path, (unsigned long)entry, (unsigned long)g_base, g_total_size);
    if (getenv("AUX_TRACE")) {
        fprintf(stderr, "[elf-runner] aux=%p a=%d slot0=%lx argc=%d\n",
                (void*)aux, a, (unsigned long)slot[0], narg);
        for (int z = 0; z < 14; z++)
            fprintf(stderr, "[elf-runner]   slot[%d]=0x%lx\n", z, (unsigned long)slot[z]);
    }
    fprintf(stderr, "[elf-runner] interpreter mode: entry=0x%lx sp=0x%lx\n",
            (unsigned long)entry, (unsigned long)slot);

    /* 14e1: 解释器执行（不回返；exit_group 由 translate_syscall 内 siglongjmp
       回 elf_runner_main 的 setjmp，主进程存活）。 */
    extern int emu_run(uint64_t entry, uint64_t sp);
    extern void emu_deactivate(void);
    int rc = emu_run(entry, (uintptr_t)slot);
    emu_deactivate();
    fprintf(stderr, "[elf-runner] interpreter returned %d\n", rc);
    return rc > 0 ? rc : (rc == 0 ? 0 : 1);
}

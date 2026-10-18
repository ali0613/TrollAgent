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
#include <signal.h>
/* iOS SDK 缺 sys/ptrace.h（ptrace 为 Darwin 私有 API）——手写声明与常量，符号在 libSystem */
#define PT_ATTACHEXC 19
#define PT_DETACH    11
extern int ptrace(int request, pid_t pid, char *addr, int data);
#include <stdbool.h>
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif

/* ---- aarch64 ELF 常量 ---- */
#define ELF_MAGIC      0x464C457F   /* \x7fELF */
#define EM_AARCH64     183
#define PT_LOAD        1
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
static uintptr_t g_base = 0;             /* 加载基址（存地址；按整数运算避免指针算术混用） */
static uintptr_t g_load_vaddr = 0;      /* 第一个段的 vaddr */
static size_t   g_total_size = 0;       /* 覆盖全部段的内存区域大小 */
static uint64_t g_syscall_num = 0;      /* 由 svc patch 记录（brk 号带 syscall#） */
static uint64_t g_phoff = 0;           /* 14c8: program header 信息（auxv AT_PHDR/AT_PHENT/AT_PHNUM） */
static uint64_t g_phentsize = 0;
static uint64_t g_phnum = 0;

/* 段保护信息（patch 完成后统一 mprotect） */
#define MAX_SEGS 32
static struct { uintptr_t off; size_t len; int prot; } g_segs[MAX_SEGS];
static int g_nsegs = 0;

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
#define SYS_readlinkat        78
#define SYS_mkdirat           34
#define SYS_unlinkat          35
#define SYS_rmdir             21
#define SYS_dup               23
#define SYS_dup3              24
#define SYS_ioctl             29
#define SYS_arch_prctl        178  /* x86 专用，aarch64 无 */

static long sys_exit(int code)          { _exit(code); return 0; }
static long sys_exit_group(int code)    { _exit(code); return 0; }
static long sys_getpid(void)            { return (long)getpid(); }
static long sys_getppid(void)           { return (long)getppid(); }
static long sys_getuid(void)            { return 0; }
static long sys_geteuid(void)           { return 0; }
static long sys_getgid(void)            { return 0; }
static long sys_getegid(void)           { return 0; }

static long sys_write(int fd, const void *buf, size_t count) {
    return (long)write(fd, buf, count);
}
static long sys_read(int fd, void *buf, size_t count) {
    return (long)read(fd, buf, count);
}
static long sys_close(int fd) {
    return (long)close(fd);
}
static long sys_lseek(int fd, off_t off, int whence) {
    return (long)lseek(fd, off, whence);
}
static long sys_openat(int dirfd, const char *path, int flags, mode_t mode) {
    return (long)openat(dirfd, path, flags, mode);
}
static long sys_faccessat(int dirfd, const char *path, int amode) {
    return (long)faccessat(dirfd, path, amode, 0);   /* Darwin 4 参（flags） */
}
static long sys_dup(int fd) {
    return (long)dup(fd);
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

static long sys_brk(uintptr_t newbrk) {
    /* iOS 无传统 brk；static 二进制通常一次性 brk 到静态堆顶，接受即可 */
    (void)newbrk;
    return 0;
}
static long sys_mmap(uintptr_t addr, size_t len, int prot, int flags, int fd, off_t off) {
    /* MAP_FIXED 支持；PROT_* 映射 iOS 相同 */
    int mprot = 0;
    if (prot & 1) mprot |= PROT_READ;
    if (prot & 2) mprot |= PROT_WRITE;
    if (prot & 4) mprot |= PROT_EXEC;
    void *r = mmap((void*)addr, len, mprot, flags, fd, off);
    if (r == MAP_FAILED) return -errno;
    return (long)(uintptr_t)r;
}
static long sys_munmap(uintptr_t addr, size_t len) {
    if (munmap((void*)addr, len) != 0) return -errno;
    return 0;
}
static long sys_nanosleep(const struct timespec *req, struct timespec *rem) {
    struct timespec r = *req;
    nanosleep(&r, rem);
    return 0;
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

/* fcntl 简化（busybox 常用 F_GETFL/F_SETFL 等） */
static long sys_fcntl(int fd, int cmd, long arg) {
    return (long)fcntl(fd, cmd, arg);
}
/* ioctl 简化（busybox 常用 TIOCGWINSZ 等） */
static long sys_ioctl(int fd, unsigned long req, long arg) {
    return (long)ioctl(fd, req, arg);
}

/* 主翻译入口：Linux syscall 号 → 本地实现 */
static long translate_syscall(uint64_t nr,
                              uint64_t a0, uint64_t a1, uint64_t a2,
                              uint64_t a3, uint64_t a4, uint64_t a5) {
    switch (nr) {
    case SYS_exit:        return sys_exit((int)a0);
    case SYS_exit_group:  return sys_exit_group((int)a0);
    case SYS_getpid:      return sys_getpid();
    case SYS_getppid:     return sys_getppid();
    case SYS_getuid:      return sys_getuid();
    case SYS_geteuid:     return sys_geteuid();
    case SYS_getgid:      return sys_getgid();
    case SYS_getegid:     return sys_getegid();
    case SYS_write:       return sys_write((int)a0, (void*)(uintptr_t)a1, (size_t)a2);
    case SYS_read:        return sys_read((int)a0, (void*)(uintptr_t)a1, (size_t)a2);
    case SYS_close:       return sys_close((int)a0);
    case SYS_lseek:       return sys_lseek((int)a0, (off_t)a1, (int)a2);
    case SYS_openat:      return sys_openat((int)a0, (const char*)(uintptr_t)a1, (int)a2, (mode_t)a3);
    case SYS_faccessat:   return sys_faccessat((int)a0, (const char*)(uintptr_t)a1, (int)a2);
    case SYS_dup:         return sys_dup((int)a0);
    case SYS_dup3:        return sys_dup3((int)a0, (int)a1, (int)a2);
    case SYS_uname:       return sys_uname((void*)(uintptr_t)a0);
    case SYS_brk:         return sys_brk((uintptr_t)a0);
    case SYS_mmap:        return sys_mmap((uintptr_t)a0, (size_t)a1, (int)a2, (int)a3, (int)a4, (off_t)a5);
    case SYS_munmap:      return sys_munmap((uintptr_t)a0, (size_t)a1);
    case SYS_nanosleep:   return sys_nanosleep((const struct timespec*)(uintptr_t)a0, (struct timespec*)(uintptr_t)a1);
    case SYS_gettimeofday:return sys_gettimeofday((void*)(uintptr_t)a0, (void*)(uintptr_t)a1);
    case SYS_clock_gettime:return sys_clock_gettime((int)a0, (void*)(uintptr_t)a1);
    case SYS_fcntl:       return sys_fcntl((int)a0, (int)a1, (long)a2);
    case SYS_ioctl:       return sys_ioctl((int)a0, (unsigned long)a1, (long)a2);
    default:
        fprintf(stderr, "[elf-runner] unsupported syscall %llu (x0=%llu x1=%llu x2=%llu)\n",
                (unsigned long long)nr,
                (unsigned long long)a0, (unsigned long long)a1, (unsigned long long)a2);
        return -ENOSYS;
    }
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

/* ---- 14c8: SIGBUS/SIGSEGV handler：抓崩溃点（PC/LR/SP/FAR）定位 ---- */
static void crash_handler(int sig, siginfo_t *si, void *ucv) {
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
static int apply_relocations(const uint8_t *raw, const Elf64_Ehdr *eh) {
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
                uint64_t *p = (uint64_t *)(g_base + rela[j].r_offset);
                *p = g_base + (uint64_t)rela[j].r_addend;
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
       iOS 禁止 MAP_JIT+MAP_FIXED（EINVAL）→ 首试固定地址仅用于诊断，正常走非固定。 */
    void *m = mmap((void *)lo, total, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON | MAP_JIT | MAP_FIXED, -1, 0);
    if (m == MAP_FAILED) {
        /* 地址冲突时退回任意地址并重定位（静态 ELF 假设固定地址，先试 MAP_FIXED） */
        fprintf(stderr, "elf-runner: mmap 0x%lx 失败 (%s)，尝试非固定映射\n",
                (unsigned long)lo, strerror(errno));
        m = mmap(NULL, total, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
        if (m == MAP_FAILED) {
            fprintf(stderr, "elf-runner: 非固定 MAP_JIT mmap 失败 (%s) total=0x%zx\n",
                    strerror(errno), total);
            free(raw); return -1;
        }
        /* 修复(iOS)：非固定映射时不得覆盖 g_load_vaddr(原始 vaddr)。
           否则下方段拷贝 dst=lo+(p_vaddr-g_load_vaddr) 回落为 p_vaddr(0x400000 未映射)→SIGSEGV。
           iOS 上 MAP_FIXED 到低地址(0x400000) 会 Cannot allocate memory，必须走非固定+相对偏移。 */
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
        g_segs[g_nsegs].off = seg_start - g_base;
        g_segs[g_nsegs].len = seg_end - seg_start;
        g_segs[g_nsegs].prot = prot;
        g_nsegs++;
    }

    /* 入口需加基址偏移（g_load_vaddr 为原始 vaddr；g_base 为实际映射基址） */
    *entry_out = g_base + (eh->e_entry - g_load_vaddr);
    fprintf(stderr, "[elf-runner] load done: entry=0x%lx\n", (unsigned long)*entry_out);

    /* 14c8: PIE 重定位(RELATIVE) 须在 free(raw) 前、段仍 RW 时执行 */
    if (apply_relocations(raw, eh) != 0) { free(raw); return -1; }

    free(raw);
    return 0;
}

/* ---- patch: svc #0 → brk #1（在加载内存内扫描；此时段仍 RW） ---- */
static int patch_svc(void) {
    int patched = 0;
    fprintf(stderr, "[elf-runner] patch scanning 0..0x%zx (base 0x%lx)\n",
            g_total_size, (unsigned long)g_base);
    for (size_t off = 0; off + 4 <= g_total_size; off += 4) {
        if ((off & 0xfffff) == 0)
            fprintf(stderr, "[elf-runner]   scan off=0x%lx\n", (unsigned long)off);
        uint32_t *insn = (uint32_t *)(g_base + off);
        if (*insn == SVC_0) {
            *insn = BRK_1;
            patched++;
        }
    }
    fprintf(stderr, "[elf-runner] patch done: %d svc sites\n", patched);
    return patched;
}

/* ---- patch 完成后统一按段设保护 ---- */
static int apply_seg_prot(void) {
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
        if (mprotect((void *)(g_base + g_segs[i].off), g_segs[i].len, g_segs[i].prot) != 0) {
            perror("mprotect seg");
            return -1;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: elf-runner <linux-aarch64-static-elf> [args...]\n");
        return 2;
    }
    const char *elf_path = argv[1];
    fprintf(stderr, "[elf-runner] START argc=%d elf=%s\n", argc, elf_path);

    /* 14c8 JIT：iOS 第三方 App 的 MAP_JIT 无法靠 dynamic-codesigning entitlement 激活
       （Apple-only；实证非固定 MAP_JIT mmap EINVAL）。TrollStore 的 JIT 机制 =
       ptrace(PT_ATTACHEXC) attach/detach 伪装调试，内核因"被调试"允许 JIT 内存。
       需 get-task-allow + task_for_pid（entitlements 已加）+ iOS16 需 Developer Mode。 */
    if (ptrace(PT_ATTACHEXC, getpid(), 0, 0) == 0) {
        usleep(100000);
        ptrace(PT_DETACH, getpid(), 0, 0);
        fprintf(stderr, "[elf-runner] JIT enabled via ptrace self-attach\n");
    } else {
        fprintf(stderr, "[elf-runner] ptrace self-attach 失败 (%s)——MAP_JIT 将不可用\n",
                strerror(errno));
    }

    uintptr_t entry = 0;
    if (load_elf(elf_path, &entry) != 0) return 1;

    /* 先 patch svc（段仍 RW），再设只读/执行保护 */
    int npatch = patch_svc();
    if (apply_seg_prot() != 0) return 1;
    fprintf(stderr, "[elf-runner] svc patched: %d syscall sites\n", npatch);

    /* 注册 SIGTRAP handler（SA_SIGINFO 才能拿 ucontext 寄存器） */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = trap_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGTRAP, &sa, NULL);

    /* 14c8: SIGBUS/SIGSEGV handler 抓崩溃 PC（若 entry 后仍崩，靠它定位） */
    sa.sa_sigaction = crash_handler;
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);

    /* 布置 Linux 初始栈（aarch64 Linux ABI）：
       sp→[argc][argv[0..n-1]][NULL][envp NULL][auxv: AT_* 对][AT_NULL]
       musl/glibc _start 从 [sp] 读 argc，argv=sp+8；auxv 需完整
       (AT_PHDR/AT_PHENT/AT_PHNUM/AT_PAGESZ/AT_ENTRY/AT_RANDOM 等)，
       缺 AT_PHDR/AT_RANDOM 时 musl 静态 PIE 启动路径会读错 → SIGBUS。 */
    int narg = argc - 1;
    uint8_t *stack = mmap(NULL, 1 << 20, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANON, -1, 0);
    if (stack == MAP_FAILED) { perror("stack"); return 1; }
    uintptr_t sp_top = (uintptr_t)stack + (1 << 20);
    sp_top &= ~(uintptr_t)15;                     /* 16 字节对齐 */
    uintptr_t *slot = (uintptr_t *)(sp_top - 512);
    uint64_t *aux = (uint64_t *)(slot + 2 + narg);  /* argv NULL 之后 */
    uint64_t rand16[2] = { 0x1234, 0x5678 };        /* AT_RANDOM（栈上） */
    int i;
    slot[0] = (uintptr_t)narg;                    /* argc */
    for (i = 0; i < narg; i++) slot[1 + i] = (uintptr_t)argv[i + 1];
    slot[1 + narg] = 0;                           /* argv NULL */
    slot[2 + narg] = 0;                           /* envp NULL(空) */
    int a = 0;
    aux[a++] = 3;  aux[a++] = g_base + g_phoff;    /* AT_PHDR */
    aux[a++] = 4;  aux[a++] = g_phentsize;         /* AT_PHENT */
    aux[a++] = 5;  aux[a++] = g_phnum;             /* AT_PHNUM */
    aux[a++] = 6;  aux[a++] = 4096;                /* AT_PAGESZ */
    aux[a++] = 7;  aux[a++] = 0;                   /* AT_BASE(静态链接=0) */
    aux[a++] = 8;  aux[a++] = 0;                   /* AT_FLAGS */
    aux[a++] = 9;  aux[a++] = entry;               /* AT_ENTRY */
    aux[a++] = 23; aux[a++] = 0;                   /* AT_SECURE */
    aux[a++] = 25; aux[a++] = (uintptr_t)rand16;   /* AT_RANDOM(16B) */
    aux[a++] = 31; aux[a++] = (uintptr_t)elf_path; /* AT_EXECFN */
    aux[a++] = 0;                                  /* AT_NULL */

    fprintf(stderr, "[elf-runner] loading %s entry=0x%lx base=0x%lx size=%zu\n",
            elf_path, (unsigned long)entry, (unsigned long)g_base, g_total_size);
    fprintf(stderr, "[elf-runner] jumping to entry=0x%lx\n", (unsigned long)entry);

    /* 手动跳转：mov sp = Linux 初始栈，br entry（aarch64；不回返） */
    register uintptr_t a0 __asm__("x0") = (uintptr_t)narg;
    (void)a0;
    __asm__ volatile(
        "mov sp, %[sp]\n\t"
        "br %[entry]\n\t"
        :
        : [sp] "r" ((uintptr_t)slot), [entry] "r" (entry)
        : "memory");
    fprintf(stderr, "[elf-runner] UNREACHABLE（entry 未返回）\n");
    return 1;
}

/* emu.c —— arm64 精简解释器（CELF target）
 *
 * 背景：iOS16.3 + TrollStore 下 MAP_JIT 无法激活（csflags 实测 debugged=0、
 * allow-jit 位不在、platform 不生效），"jump 直跑"在可执行内存上取指必 SIGBUS。
 * 解释器把已加载 ELF 的指令当数据处理逐条解码执行，不需要可执行内存——
 * 绕开 iOS W^X 硬墙。svc 指令直接复用 elf-runner.c 的 translate_syscall。
 *
 * 覆盖：busybox/musl 静态链接常用指令（整数 ALU、分支、访存、地址计算、
 * movz/movk、mrs/msr TPIDR_EL0、缓存维护/屏障 NOP）。
 * 未支持指令：打印编码并退出（迭代补齐）。NEON 暂未支持。
 *
 * arm64 语义要点：x31 读源=ZR(0)、写目标=SP；ADD/SUB(imm/reg) 的 Rn=31=SP，
 * ADDS/SUBS/逻辑的 Rn=31=ZR；访存/分支地址的 Rn=31=SP。
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <setjmp.h>

extern uintptr_t g_base;
extern size_t g_total_size;
extern long translate_syscall(uint64_t nr, uint64_t a0, uint64_t a1, uint64_t a2,
                              uint64_t a3, uint64_t a4, uint64_t a5);
extern int g_emu_halt;   /* v19: syscall_layer 的 exit_group 置位，本地驱动据此停止 */
extern int g_exit_code;

typedef struct {
    uint64_t r[31];
    uint64_t sp;
    uint64_t pc;
    uint32_t nzcv;
    uint64_t tpidr;
    uint64_t v[32][2];          /* NEON 128 位向量寄存器（低/高 64） */
    long exit_code;
    int exited;
} Emu;

static Emu E;
static uint64_t g_slot = 0;
static jmp_buf g_emu_jmp;
static int g_emu_active = 0;

/* v11: 指令 ring buffer —— 崩前最后 64 条 (pc, insn)，longjmp 时带出，定位访存来源 */
#define TR_RING 64
static uint64_t tr_pc[TR_RING];
static uint32_t tr_insn[TR_RING];
static int tr_idx = 0;
static void tr_record(uint64_t pc, uint32_t insn) {
    tr_pc[tr_idx] = pc;
    tr_insn[tr_idx] = insn;
    tr_idx = (tr_idx + 1) % TR_RING;
}
static void tr_dump(void) {
    int n = 0, i = tr_idx;
    fprintf(stderr, "[emu] -- crash trail (last %d) --\n", TR_RING);
    for (; n < TR_RING; n++) {
        i = (i + TR_RING - 1) % TR_RING;
        if (!tr_pc[i]) continue;
        fprintf(stderr, "  t%02d 0x%08llx: %08x\n",
            n, (unsigned long long)tr_pc[i], (unsigned)tr_insn[i]);
    }
    fprintf(stderr, "[emu] -- end trail --\n");
}

/* x31 读=ZR(0)；x31 写=SP（W 处理） */
static uint64_t RZR(int n) { return n == 31 ? 0 : E.r[n]; }
static uint64_t RSP(int n) { return n == 31 ? E.sp : E.r[n]; }
static void W(int n, uint64_t v) {
    if (getenv("EMU_W5") && n == 5) fprintf(stderr, "W5 pc=0x%llx v=0x%llx\n", (unsigned long long)E.pc, (unsigned long long)v);
    if (n == 31) E.sp = v; else if (n < 31) E.r[n] = v;
}

static uint32_t fetch(void) {
    uint32_t insn = 0;
    if (E.pc >= g_base && E.pc + 4 <= g_base + g_total_size) {
        memcpy(&insn, (void *)(uintptr_t)E.pc, 4);
    } else {
        fprintf(stderr, "[emu] fetch OOB pc=0x%llx (base=0x%llx size=%zu)\n",
                (unsigned long long)E.pc, (unsigned long long)g_base, g_total_size);
        E.exited = 1; E.exit_code = -EFAULT; return 0;
    }
    return insn;
}

static int64_t sext(uint64_t v, int bits) {
    if (bits < 64 && (v & (1ULL << (bits - 1)))) v |= ~((1ULL << bits) - 1);
    return (int64_t)v;
}
static int rd(uint32_t i) { return i & 0x1F; }
static int rn(uint32_t i) { return (i >> 5) & 0x1F; }
static int rm(uint32_t i) { return (i >> 16) & 0x1F; }

static uint64_t shift_reg(uint64_t v, uint32_t i) {
    int sh = (i >> 22) & 3, amt = (i >> 10) & 0x3F;
    switch (sh) {
    case 0: return v << amt;
    case 1: return v >> amt;
    case 2: return (int64_t)v >> amt;
    default: return amt ? (v >> amt) | (v << (64 - amt)) : v;
    }
}

/* arm64 逻辑立即数（bitmask）解码：N:immr:imms → 实际掩码 */
static uint64_t decode_bitmask(int N, int immr, int imms, int sf, int *valid) {
    int len = 31 - __builtin_clz((N << 6) | ((~imms) & 0x3F));
    if (len < 1 || (len == 7 && !sf)) { *valid = 0; return 0; }
    int levels = (1 << len) - 1;
    int s = imms & levels, r = immr & levels;
    uint64_t mask;
    if (s == levels) mask = ~0ULL;
    else mask = (1ULL << (s + 1)) - 1;
    uint64_t full = (levels + 1 == 64) ? ~0ULL : ((1ULL << (levels + 1)) - 1);
    if (r != 0)
        mask = ((mask >> r) | (mask << (levels + 1 - r))) & full;
    if (levels != 63) mask &= (1ULL << (levels + 1)) - 1;
    /* v19: 按周期扩展到 64 位（此前缺失 → SWAR bitmask 只算出低位，strchr 失效） */
    {
        int step = levels + 1;
        if (step < 64 && mask) {
            uint64_t rep = mask;
            for (int i = step; i < 64; i += step) mask |= rep << i;
        }
    }
    if (!sf) mask &= 0xFFFFFFFF;
    *valid = 1;
    return mask;
}

static void set_nzcv(uint64_t res, uint64_t a, uint64_t b, int sf, int is_sub) {
    uint64_t mask = sf ? ~0ULL : 0xFFFFFFFFULL;
    uint64_t r = res & mask, aa = a & mask, bb = b & mask;
    uint32_t f = 0;
    if (r >> (sf ? 63 : 31)) f |= 1u << 31;
    if (r == 0) f |= 1u << 30;
    if (is_sub) { if (aa >= bb) f |= 1u << 29; }
    else        { if (r < aa)  f |= 1u << 29; }
    uint64_t sign = 1ULL << (sf ? 63 : 31);
    if (is_sub) { if ((aa & sign) != (bb & sign) && (r & sign) == (bb & sign)) f |= 1u << 28; }
    else        { if ((aa & sign) == (bb & sign) && (r & sign) != (aa & sign)) f |= 1u << 28; }
    E.nzcv = f;
}

static int cond_true(unsigned c) {
    uint32_t f = E.nzcv;
    int n = (f >> 31) & 1, z = (f >> 30) & 1, cv = (f >> 29) & 1, v = (f >> 28) & 1;
    int base;
    switch (c & 0xE) {
    case 0x0: base = z; break;                       /* EQ/NE */
    case 0x2: base = cv; break;                      /* CS/CC */
    case 0x4: base = n; break;                       /* MI/PL */
    case 0x6: base = v; break;                       /* VS/VC */
    case 0x8: base = cv && !z; break;                /* HI/LS */
    case 0xA: base = n == v; break;                  /* GE/LT */
    case 0xC: base = !z && n == v; break;            /* GT/LE */
    default:  return 1;                              /* AL/NV */
    }
    return (c & 1) ? !base : base;                   /* 奇数条件码取反 */
}

/* 内存访问：直接访问；非法地址由 SIGSEGV → crash_handler(emu) → longjmp 兜底 */
static void *mem_p(uint64_t a) { return (void *)(uintptr_t)a; }
static uint64_t mem_ld(uint64_t a, int bytes) {
    if (getenv("EMU_MEM")) fprintf(stderr, "MEM_LD addr=0x%llx bytes=%d pc=0x%llx\n", (unsigned long long)a, bytes, (unsigned long long)E.pc);
    void *p = mem_p(a);
    switch (bytes) {
    case 1: return *(uint8_t *)p;
    case 2: { uint16_t v; memcpy(&v, p, 2); return v; }
    case 4: { uint32_t v; memcpy(&v, p, 4); return v; }
    default:{ uint64_t v; memcpy(&v, p, 8); return v; }
    }
}
static void mem_st(uint64_t a, uint64_t v, int bytes) {
    if (getenv("EMU_WST") && (a == g_slot || a == g_slot + 8 || (a >= E.sp - 0x300ULL && a <= E.sp + 0x230ULL)))
        fprintf(stderr, "[wst] pc=0x%llx off=%#llx st [%llx] <- %llx (%d)\n", (unsigned long long)E.pc,
                (unsigned long long)(E.pc - g_base), (unsigned long long)a, (unsigned long long)v, bytes);
    void *p = mem_p(a);
    switch (bytes) {
    case 1: *(uint8_t *)p = (uint8_t)v; break;
    case 2: memcpy(p, &v, 2); break;
    case 4: { uint32_t x = (uint32_t)v; memcpy(p, &x, 4); break; }
    default: memcpy(p, &v, 8); break;
    }
}

static int unsupported(uint32_t i) {
    fprintf(stderr, "[emu] UNSUPPORTED insn pc=0x%llx insn=0x%08x\n",
            (unsigned long long)E.pc, i);
    E.exited = 1; E.exit_code = -ENOSYS;
    return 1;
}

static int g_iotrace = 0;   /* v18: ioctl 后指令轨迹开关 */
static int exec_one(void) {
    /* v11: 每条指令进 ring buffer（崩点带出最后 64 条） */
    tr_record(E.pc, E.pc >= g_base && E.pc + 4 <= g_base + g_total_size
                  ? *(const uint32_t *)(uintptr_t)E.pc : 0);
    if (g_iotrace)
        fprintf(stderr, "[it] pc-off=0x%llx insn=0x%08x\n",
                (unsigned long long)(E.pc - g_base),
                (unsigned int)(E.pc >= g_base && E.pc + 4 <= g_base + g_total_size
                    ? *(const uint32_t *)(uintptr_t)E.pc : 0));
    if (getenv("EMU_DBG")) {
        uint64_t offd = E.pc - g_base;
        if (offd == 0x10928ULL)
            fprintf(stderr, "[dbg] 10928 x0=%#llx x1=%#llx x19=%#llx x20=%#llx\n",
                (unsigned long long)E.r[0], (unsigned long long)E.r[1],
                (unsigned long long)E.r[19], (unsigned long long)E.r[20]);
        if (offd == 0x10520ULL) {
            uint64_t f = *(uint64_t*)(uintptr_t)(g_base + 0x13c038ULL + E.r[20]*8);
            fprintf(stderr, "[dbg] applet w20=%u funcoff=%#llx g_base=%#llx argv=%#llx\n",
                (unsigned)E.r[20], (unsigned long long)(f - (uint64_t)g_base),
                (unsigned long long)g_base, (unsigned long long)E.r[22]);
        }
        if (offd == 0x113a0ULL)
            fprintf(stderr, "[dbg] exit-entry [0x13d330]=%u x0=%#llx\n",
                (unsigned)*(uint8_t*)(uintptr_t)(g_base + 0x13d330ULL),
                (unsigned long long)E.r[0]);
        if (offd == 0x113b4ULL)
            fprintf(stderr, "[dbg] exit-ldrb x0=%#llx [0x13d330]=%u\n",
                (unsigned long long)E.r[0],
                (unsigned)*(uint8_t*)(uintptr_t)(g_base + 0x13d330ULL));
        if (offd == 0x10528ULL)
            fprintf(stderr, "[dbg] blr x2=%#llx (off=%#llx)\n",
                (unsigned long long)E.r[2], (unsigned long long)(E.r[2] - (uint64_t)g_base));
        if (offd == 0xabaf0ULL) {
            uint64_t *ap = (uint64_t*)(uintptr_t)E.r[1];
            fprintf(stderr, "[dbg] echo_main argc=%llu argv0='%.12s' argv1='%.12s' argv2='%.12s' argv3='%.12s'\n",
                (unsigned long long)E.r[0],
                (char*)(uintptr_t)ap[0], (char*)(uintptr_t)ap[1],
                (char*)(uintptr_t)ap[2], (char*)(uintptr_t)ap[3]);
        }
    }
    if (getenv("EMU_TRACE"))
        fprintf(stderr, "TRACE pc=0x%llx insn=0x%08x x0=0x%llx x1=0x%llx x2=0x%llx x19=0x%llx x20=0x%llx x21=0x%llx x23=0x%llx x24=0x%llx x30=0x%llx sp=0x%llx\n",
            (unsigned long long)E.pc, (unsigned)(*(volatile uint32_t *)(uintptr_t)E.pc),
            (unsigned long long)E.r[0], (unsigned long long)E.r[1],
            (unsigned long long)E.r[2], (unsigned long long)E.r[19], (unsigned long long)E.r[20],
            (unsigned long long)E.r[21], (unsigned long long)E.r[23], (unsigned long long)E.r[24],
            (unsigned long long)E.r[30], (unsigned long long)E.sp);

    if (getenv("EMU_BP")) {
        uint64_t off = E.pc - g_base;
        if (off == 0x1091cULL || off == 0x10924ULL || off == 0x10538ULL || off == 0x10928ULL || off == 0x3146cULL || off == 0xffbcULL || off == 0x31460ULL || off == 0x31474ULL || off == 0xddf54ULL || off == 0xdd5e4ULL || off == 0xddf88ULL || off == 0x9304ULL || off == 0x9300ULL || off == 0xfd00ULL || off == 0xfc08ULL || off == 0xfc04ULL || off == 0xfc3cULL || off == 0xf4e18ULL || off == 0xf4d70ULL || off == 0xf4f2cULL || off == 0xf4d8cULL || off == 0xf4d90ULL || off == 0xf4f44ULL || off == 0xf4f60ULL || off == 0xf4f5cULL || off == 0xf4fb4ULL || off == 0xf4fb8ULL || off == 0xf4fbcULL || off == 0xf4ee4ULL || off == 0xf4ef0ULL || off == 0xf4f08ULL || off == 0xf4ea0ULL || off == 0xf4ee8ULL || off == 0xf4e5cULL || off == 0xf4ea8ULL || off == 0xf4eacULL || off == 0xf4ed0ULL || off == 0xf4d00ULL || off == 0xf4d04ULL || off == 0xf4cf0ULL || off == 0x10914ULL || off == 0x10918ULL || off == 0xffbcULL || off == 0x10078ULL || off == 0x1008cULL || off == 0xffc0ULL || off == 0xffd4ULL || off == 0xfff4ULL || off == 0x10028ULL || off == 0x10060ULL || off == 0x1006cULL || off == 0xffd8ULL || off == 0xfff8ULL || off == 0x1002cULL || off == 0x10064ULL) {
            if (off == 0xf4ee4ULL || off == 0xf4ef0ULL)
                fprintf(stderr, "  x5=0x%llx x2=0x%llx [x5+0x20]=0x%llx [x2+0x20]=0x%llx\n",
                    (unsigned long long)E.r[5], (unsigned long long)E.r[2],
                    (unsigned long long)*(uint64_t*)(E.r[5]+0x20),
                    (unsigned long long)*(uint64_t*)(E.r[2]+0x20));
            if (off == 0x1091cULL) {
                fprintf(stderr, "[dbg] 1091c x19=%#llx [x19+0x370]=%#llx x20=%#llx\n", (unsigned long long)E.r[19], (unsigned long long)*(uint64_t*)(E.r[19]+0x370), (unsigned long long)E.r[20]);
            }
            if (off == 0x10924ULL) {
                uint64_t *ap = (uint64_t*)(uintptr_t)E.r[1];
                fprintf(stderr, "[dbg] 10924 x0='%.40s' argv0='%.20s' argv1='%.20s' argv2='%.20s'\n",
                    (char*)(uintptr_t)E.r[0], (char*)(uintptr_t)ap[0], (char*)(uintptr_t)ap[1], (char*)(uintptr_t)ap[2]);
            }
            if (off == 0x10538ULL) {
                fprintf(stderr, "[dbg] 10538 x0='%.40s' x1='%.40s' x2=%#llx\n", (char*)(uintptr_t)E.r[0], (char*)(uintptr_t)E.r[1], (unsigned long long)E.r[2]);
            }
            if (off == 0x10928ULL) {
                fprintf(stderr, "[dbg] 10928 x0=%#llx x1=%#llx '%s' argv1=%#llx '%s'\n",
                    (unsigned long long)E.r[0], (unsigned long long)E.r[1], (char*)(uintptr_t)E.r[1],
                    (unsigned long long)(E.r[20]?*(uint64_t*)(E.r[20]+8):0),
                    (char*)(E.r[20]?*(uint64_t*)(E.r[20]+8):0));
            }
            if (off == 0x3146cULL) {
                fprintf(stderr, "[dbg] l3146c after-adrp x0=%#llx\n", (unsigned long long)E.r[0]);
            }
            if (off == 0xffbcULL) {
                g_slot = E.sp - 0x1f0;
                fprintf(stderr, "[dbg] argv0 ptr=%#llx str=\"%.60s\" sp=%#llx\n",
                    (unsigned long long)E.r[0], (char *)(uintptr_t)E.r[0], (unsigned long long)E.sp);
            }
            if (off == 0xfc04ULL) {
                fprintf(stderr, "[dbg] andsp x0=%#llx sp_before=%#llx\n", (unsigned long long)E.r[0], (unsigned long long)E.sp);
            }
            if (off == 0xfc08ULL) {
                fprintf(stderr, "[dbg] b-fc3c sp=%#llx x0=%#llx\n", (unsigned long long)E.sp, (unsigned long long)E.r[0]);
            }
            if (off == 0xfd00ULL) {
                fprintf(stderr, "[dbg] brx16 x16=%#llx x0=%#llx x1=%#llx x2=%#llx x3=%#llx sp=%#llx\n",
                    (unsigned long long)E.r[16], (unsigned long long)E.r[0], (unsigned long long)E.r[1],
                    (unsigned long long)E.r[2], (unsigned long long)E.r[3], (unsigned long long)E.sp);
                uint64_t p = E.r[1];
                fprintf(stderr, "[dbg] stack0 argc=%llu a0=%#llx\"%s\" a1=%#llx\"%s\" a2=%#llx\"%s\" a3=%#llx\"%s\"\n",
                    (unsigned long long)*(uint64_t*)p,
                    (unsigned long long)*(uint64_t*)(p+8), (char*)(uintptr_t)*(uint64_t*)(p+8),
                    (unsigned long long)*(uint64_t*)(p+16), (char*)(uintptr_t)*(uint64_t*)(p+16),
                    (unsigned long long)*(uint64_t*)(p+24), (char*)(uintptr_t)*(uint64_t*)(p+24),
                    (unsigned long long)*(uint64_t*)(p+32), (char*)(uintptr_t)*(uint64_t*)(p+32));
            }
            if (off == 0x1091cULL) {
                fprintf(stderr, "[dbg] 1091c x19=%#llx [x19+0x370]=%#llx x20=%#llx\n", (unsigned long long)E.r[19], (unsigned long long)*(uint64_t*)(E.r[19]+0x370), (unsigned long long)E.r[20]);
            }
            if (off == 0x10924ULL) {
                uint64_t *ap = (uint64_t*)(uintptr_t)E.r[1];
                fprintf(stderr, "[dbg] 10924 x0='%.40s' argv0='%.20s' argv1='%.20s' argv2='%.20s'\n",
                    (char*)(uintptr_t)E.r[0], (char*)(uintptr_t)ap[0], (char*)(uintptr_t)ap[1], (char*)(uintptr_t)ap[2]);
            }
            if (off == 0x10538ULL) {
                fprintf(stderr, "[dbg] 10538 x0='%.40s' x1='%.40s' x2=%#llx\n", (char*)(uintptr_t)E.r[0], (char*)(uintptr_t)E.r[1], (unsigned long long)E.r[2]);
            }
            if (off == 0x10928ULL) {
                fprintf(stderr, "[dbg] 10928 x0=%#llx x1=%#llx '%s' argv1=%#llx '%s'\n",
                    (unsigned long long)E.r[0], (unsigned long long)E.r[1], (char*)(uintptr_t)E.r[1],
                    (unsigned long long)(E.r[20]?*(uint64_t*)(E.r[20]+8):0),
                    (char*)(E.r[20]?*(uint64_t*)(E.r[20]+8):0));
            }
            if (off == 0x3146cULL) {
                fprintf(stderr, "[dbg] l3146c after-adrp x0=%#llx\n", (unsigned long long)E.r[0]);
            }
            if (off == 0xffbcULL) {
                fprintf(stderr, "[dbg] ffbc x0=%#llx '%s' x1=%#llx x2=%#llx\n", (unsigned long long)E.r[0], (char*)(E.r[0] ? (void*)E.r[0] : (void*)"?"), (unsigned long long)E.r[1], (unsigned long long)E.r[2]);
            }
            if (off == 0x31460ULL) {
                fprintf(stderr, "[dbg] l31460 x0=%#llx [sp+0x98]=%#llx\n", (unsigned long long)E.r[0], (unsigned long long)*(uint64_t*)(E.sp+0x98));
            }
            if (off == 0x31474ULL) {
                fprintf(stderr, "[dbg] l31474 x22=%#llx w25=%#x x0=%#llx x19=%#llx\n", (unsigned long long)E.r[22], (unsigned)(E.r[25] & 0xFFFFFFFF), (unsigned long long)E.r[0], (unsigned long long)E.r[19]);
            }
            if (off == 0xddf54ULL) {
                fprintf(stderr, "[dbg] cls-ent x0=%#llx\n", (unsigned long long)E.r[0]);
            }
            if (off == 0xdd5e4ULL) {
                fprintf(stderr, "[dbg] cls-ret w0=%#x\n", (unsigned)(E.r[0] & 0xFFFFFFFF));
            }
            if (off == 0xddf88ULL) {
                fprintf(stderr, "[dbg] cls-w20 w20=%#x\n", (unsigned)(E.r[20] & 0xFFFFFFFF));
            }
            if (off == 0x9300ULL) {
                fprintf(stderr, "[dbg] strlen x0=%#llx x1=%#llx sp=%#llx\n", (unsigned long long)E.r[0], (unsigned long long)E.r[1], (unsigned long long)E.sp);
            }
            if (off == 0x9304ULL) {
                fprintf(stderr, "[dbg] strlen+4 x0=%#llx x1=%#llx\n", (unsigned long long)E.r[0], (unsigned long long)E.r[1]);
            }
            if (off == 0x10914ULL) {
                fprintf(stderr, "[dbg] main-10914 x0=%#llx x1=%#llx x19=%#llx x20=%#llx x21=%#llx sp=%#llx\n",
                    (unsigned long long)E.r[0], (unsigned long long)E.r[1],
                    (unsigned long long)E.r[19], (unsigned long long)E.r[20], (unsigned long long)E.r[21], (unsigned long long)E.sp);
            }
            if (off == 0xfc3cULL) {
                uint64_t p = E.r[0];
                fprintf(stderr, "[dbg] start x0=%#llx argc=%llu argv0=%#llx\"%s\" argv1=%#llx\"%s\" argv2=%#llx\"%s\" esp=%#llx\n",
                    (unsigned long long)p,
                    (unsigned long long)*(uint64_t*)p,
                    (unsigned long long)*(uint64_t*)(p+8), (char*)(uintptr_t)*(uint64_t*)(p+8),
                    (unsigned long long)*(uint64_t*)(p+16), (char*)(uintptr_t)*(uint64_t*)(p+16),
                    (unsigned long long)*(uint64_t*)(p+24), (char*)(uintptr_t)*(uint64_t*)(p+24),
                    (unsigned long long)E.sp);
            }
        if (off == 0xf4cf0ULL || off == 0xf4d60ULL || off == 0x10914ULL || off == 0x10918ULL || off == 0xffbcULL || off == 0x10078ULL || off == 0x1008cULL || off == 0xffd8ULL || off == 0xfff8ULL || off == 0x1002cULL || off == 0x10064ULL)
                fprintf(stderr, "  sp=0x%llx [sp]=0x%llx [sp+8]=0x%llx x30=0x%llx x19=0x%llx x20=0x%llx\n",
                    (unsigned long long)E.sp,
                    (unsigned long long)*(uint64_t*)E.sp,
                    (unsigned long long)*(uint64_t*)(E.sp + 8),
                    (unsigned long long)E.r[30], (unsigned long long)E.r[19], (unsigned long long)E.r[20]);
            fprintf(stderr, "BP off=%#llx ", (unsigned long long)off);
            for (int k = 0; k < 31; k++) fprintf(stderr, "x%d=0x%llx ", k, (unsigned long long)E.r[k]);
            fprintf(stderr, "sp=0x%llx\n", (unsigned long long)E.sp);
            if (off == 0xf4e18ULL) {
                fprintf(stderr, "  [x0+0x18]=0x%llx [x0+0x20]=0x%llx [x0+0x28]=0x%llx [x0]=0x%llx\n",
                    (unsigned long long)*(uint64_t*)(E.r[0]+0x18),
                    (unsigned long long)*(uint64_t*)(E.r[0]+0x20),
                    (unsigned long long)*(uint64_t*)(E.r[0]+0x28),
                    (unsigned long long)*(uint64_t*)(E.r[0]));
                fprintf(stderr, "  [base+0x13e160+0x18]=0x%llx [+0x20]=0x%llx [+0x28]=0x%llx [0x13ea08]=0x%llx [0x13e9f8]=0x%llx [0x13ea00]=0x%llx\n",
                    (unsigned long long)*(uint64_t*)(g_base+0x13e178),
                    (unsigned long long)*(uint64_t*)(g_base+0x13e180),
                    (unsigned long long)*(uint64_t*)(g_base+0x13e188),
                    (unsigned long long)*(uint64_t*)(g_base+0x13ea08),
                    (unsigned long long)*(uint64_t*)(g_base+0x13e9f8),
                    (unsigned long long)*(uint64_t*)(g_base+0x13ea00));
                fprintf(stderr, "  [base+0x1040..0x1060]=0x%llx 0x%llx 0x%llx 0x%llx\n",
                    (unsigned long long)*(uint64_t*)(g_base+0x1040),
                    (unsigned long long)*(uint64_t*)(g_base+0x1048),
                    (unsigned long long)*(uint64_t*)(g_base+0x1050),
                    (unsigned long long)*(uint64_t*)(g_base+0x1058));
            }
        }
    }
    uint32_t i = fetch();
    if (E.exited) return 1;

    /* ---- SVC ---- */
    if ((i & 0xFF000000) == 0xD4000000) {
        /* aarch64 Linux ABI: syscall nr 在 x8（musl 裸 svc 直接 mov x8,nr;
           musl __syscall 封装也是 mov x8,x16 后再 svc，x8 恒为真值） */
        uint64_t nr = E.r[8];
        if (nr == 0 && E.r[16] != 0) nr = E.r[16];   /* 兜底：部分旧封装只放 x16 */
        uint64_t ret = translate_syscall(nr, E.r[0], E.r[1], E.r[2],
                                         E.r[3], E.r[4], E.r[5]);
        if (g_emu_halt) { E.exited = 1; E.exit_code = (int)g_exit_code; }
        if (nr == 64 && g_base && getenv("EMU_DBG"))
            fprintf(stderr, "[svc] write fd=%llu pc-off=%#llx lr-off=%#llx n=%llu buf='%.20s' chain=%#llx/%#llx/%#llx/%#llx\n",
                (unsigned long long)E.r[0],
                (unsigned long long)(E.pc - (uint64_t)g_base),
                (unsigned long long)(E.r[30] - (uint64_t)g_base),
                (unsigned long long)E.r[2],
                (char*)(uintptr_t)E.r[1],
                (unsigned long long)(*(uint64_t*)(uintptr_t)E.sp - (uint64_t)g_base),
                (unsigned long long)(*(uint64_t*)(uintptr_t)(E.sp + 8) - (uint64_t)g_base),
                (unsigned long long)(*(uint64_t*)(uintptr_t)(E.sp + 16) - (uint64_t)g_base),
                (unsigned long long)(*(uint64_t*)(uintptr_t)(E.sp + 24) - (uint64_t)g_base));
        E.r[0] = (uint64_t)ret;
        E.pc += 4;
        return 0;
    }

    /* ---- NOP / 屏障 / 缓存维护 / SYS ---- */
    if (i == 0xD503201F) { E.pc += 4; return 0; }
    if ((i & 0xFFFFF01F) == 0xD503301F) { E.pc += 4; return 0; }   /* DMB/DSB/ISB */
    if ((i & 0xFFF80000) == 0xD5000000) { E.pc += 4; return 0; }   /* SYS/DC/IC/AT */

    /* ---- 分支 ---- */
    if ((i & 0x7C000000) == 0x14000000) {                 /* B/BL（bit31=1 是 BL） */
        if ((i >> 31) & 1) E.r[30] = E.pc + 4;
        E.pc += (uint64_t)sext(i & 0x03FFFFFF, 26) << 2;
        return 0;
    }
    if ((i & 0xFFFFFC1F) == 0xD61F0000) { E.pc = RSP(rn(i)); return 0; }
    if ((i & 0xFFFFFC1F) == 0xD63F0000) { E.r[30] = E.pc + 4; E.pc = RSP(rn(i)); return 0; }
    if ((i & 0xFFFFFC1F) == 0xD65F0000) { E.pc = RSP(rn(i)); return 0; }

    if ((i & 0xFF000010) == 0x54000000) {
        if (cond_true(i & 0xF)) E.pc += (uint64_t)sext((i >> 5) & 0x7FFFF, 19) << 2;
        else E.pc += 4;
        return 0;
    }
    if ((i & 0x7F000000) == 0x34000000) {                /* CBZ（sf=bit31） */
        uint64_t t = RZR(rd(i));
        if (!((i >> 31) & 1)) t &= 0xFFFFFFFF;
        if (t == 0) E.pc += (uint64_t)sext((i >> 5) & 0x7FFFF, 19) << 2;
        else E.pc += 4;
        return 0;
    }
    if ((i & 0x7F000000) == 0x35000000) {                /* CBNZ（sf=bit31） */
        uint64_t t = RZR(rd(i));
        if (!((i >> 31) & 1)) t &= 0xFFFFFFFF;
        if (t != 0) E.pc += (uint64_t)sext((i >> 5) & 0x7FFFF, 19) << 2;
        else E.pc += 4;
        return 0;
    }
    if ((i & 0x7E000000) == 0x36000000) {                /* TBZ/TBNZ（sf=bit31, op=bit24） */
        int bit = ((i >> 19) & 0x1F) | (((i >> 31) & 1) << 5);
        int test = (RZR(rd(i)) >> bit) & 1;
        if (test == (((i >> 24) & 1) != 0)) E.pc += (uint64_t)sext((i >> 5) & 0x3FFF, 14) << 2;
        else E.pc += 4;
        return 0;
    }

    /* ---- ADR/ADRP ---- */
    if ((i & 0x9F000000) == 0x90000000) {
        uint64_t imm = (((i >> 5) & 0x7FFFF) << 2) | ((i >> 29) & 3);
        W(rd(i), (E.pc & ~0xFFFULL) + (uint64_t)sext(imm, 21) * 4096);
        E.pc += 4;
        return 0;
    }
    if ((i & 0x9F000000) == 0x10000000) {
        uint64_t imm = (((i >> 5) & 0x7FFFF) << 2) | ((i >> 29) & 3);
        W(rd(i), E.pc + (uint64_t)sext(imm, 21));
        E.pc += 4;
        return 0;
    }

    /* ---- MOVZ/MOVN/MOVK ---- */
    if ((i & 0x7F800000) == 0x52800000) {                /* MOVZ（sf=bit31） */
        int sf = (i >> 31) & 1, hw = (i >> 21) & 3;
        uint64_t v = (uint64_t)((i >> 5) & 0xFFFF) << (hw * 16);
        if (!sf) v &= 0xFFFFFFFF;
        W(rd(i), v); E.pc += 4; return 0;
    }
    if ((i & 0x7F800000) == 0x12800000) {                /* MOVN（sf=bit31） */
        int sf = (i >> 31) & 1, hw = (i >> 21) & 3;
        uint64_t v = ~((uint64_t)((i >> 5) & 0xFFFF) << (hw * 16));
        if (!sf) v &= 0xFFFFFFFF;
        W(rd(i), v); E.pc += 4; return 0;
    }
    if ((i & 0x7F800000) == 0x72800000) {                /* MOVK（sf=bit31） */
        int sf = (i >> 31) & 1, hw = (i >> 21) & 3;
        uint64_t v = RZR(rd(i));
        uint64_t part = (uint64_t)((i >> 5) & 0xFFFF) << (hw * 16);
        v = (v & ~(0xFFFFULL << (hw * 16))) | part;
        if (!sf) v &= 0xFFFFFFFF;
        W(rd(i), v); E.pc += 4; return 0;
    }

    /* ---- 立即数 ALU：ADD/ADDS/SUB/SUBS ---- */
    {
        uint32_t m = i & 0x7F000000;
        int is_add = -1, setf = 0;
        if (m == 0x11000000) { is_add = 1; } else if (m == 0x31000000) { is_add = 1; setf = 1; }
        else if (m == 0x51000000) { is_add = 0; } else if (m == 0x71000000) { is_add = 0; setf = 1; }
        if (is_add >= 0) {
            int sf = (i >> 31) & 1;
            uint64_t imm = (i >> 10) & 0xFFF;
            if ((i >> 22) & 1) imm <<= 12;
            uint64_t a = setf ? RZR(rn(i)) : RSP(rn(i));   /* ADD/SUB: Rn=31→SP；ADDS/SUBS: →ZR */
            uint64_t res = is_add ? a + imm : a - imm;
            if (!sf) res &= 0xFFFFFFFF;
            if (setf) { set_nzcv(res, a, imm, sf, !is_add); if (rd(i) != 31) W(rd(i), res); }
            else W(rd(i), res);
            E.pc += 4;
            return 0;
        }
    }

    /* ---- 逻辑立即数：AND/ORR/EOR/ANDS（bitmask） ---- */
    {
        uint32_t m = i & 0x7F800000;
        int kind = -1, setf = 0;
        if (m == 0x12000000 || m == 0x92000000) kind = 0;                    /* AND（W/X） */
        else if (m == 0x32000000 || m == 0xB2000000) kind = 1;               /* ORR */
        else if (m == 0x52000000 || m == 0xD2000000) kind = 2;               /* EOR */
        else if (m == 0x72000000 || m == 0xF2000000) { kind = 0; setf = 1; } /* ANDS */
        if (kind >= 0) {
            int sf = (i >> 31) & 1;
            int N = (i >> 22) & 1, immr = (i >> 16) & 0x3F, imms = (i >> 10) & 0x3F;
            int valid = 0;
            uint64_t mask = decode_bitmask(N, immr, imms, sf, &valid);
            if (!valid) return unsupported(i);
            uint64_t a = RZR(rn(i)), res;
            switch (kind) {
            case 0: res = a & mask; break;
            case 1: res = a | mask; break;
            default: res = a ^ mask; break;
            }
            if (setf) { set_nzcv(res, a, mask, sf, 0); if (rd(i) != 31) W(rd(i), res); }
            else W(rd(i), res);
            E.pc += 4;
            return 0;
        }
    }

    /* ---- 寄存器 ALU：ADD/ADDS/SUB/SUBS/AND/ANDS/ORR/EOR/BIC/ORN/EON ---- */
    {
        uint32_t m = i & 0x7F000000;
        int kind = -1, setf = 0;
        if (m == 0x0B000000) kind = 0;                       /* ADD */
        else if (m == 0x2B000000) { kind = 0; setf = 1; }    /* ADDS */
        else if (m == 0x4B000000) kind = 1;                  /* SUB */
        else if (m == 0x6B000000) { kind = 1; setf = 1; }    /* SUBS */
        else if (m == 0x0A000000) kind = 2;                  /* AND */
        else if (m == 0x6A000000) { kind = 2; setf = 1; }    /* ANDS */
        else if (m == 0x2A000000) kind = 3;                  /* ORR */
        else if (m == 0x4A000000) kind = 4;                  /* EOR */
        if (kind >= 0) {
            int sf = (i >> 31) & 1;
            int is_logic = kind >= 2;
            /* ADD/SUB（shifted register）Rn=31 → ZR；仅 extended register 的
               ADD/SUB（无 S）Rn=31 → SP；ADDS/SUBS/逻辑 → ZR */
            int is_ext = !is_logic && ((i >> 21) & 1);
            uint64_t a = (is_ext && !setf) ? RSP(rn(i)) : RZR(rn(i));
            uint64_t b, s;
            if (!is_logic && ((i >> 21) & 1)) {
                /* extended register：option=bit15-13，imm3=bit12-10 */
                uint64_t rmv = RZR(rm(i));
                switch ((i >> 13) & 7) {
                case 0: b = (uint32_t)rmv; break;                 /* UXTB */
                case 1: b = (uint32_t)(rmv & 0xFFFF); break;      /* UXTH */
                case 2: b = (uint32_t)rmv; break;                 /* UXTW */
                case 3: b = rmv; break;                           /* UXTX */
                case 4: b = (int64_t)(int32_t)(int8_t)rmv; break; /* SXTB */
                case 5: b = (int64_t)(int32_t)(int16_t)rmv; break;/* SXTH */
                case 6: b = (int64_t)(int32_t)rmv; break;         /* SXTW */
                default: b = (int64_t)rmv; break;                 /* SXTX */
                }
                s = b << ((i >> 10) & 7);
            } else {
                b = RZR(rm(i));
                if (is_logic && ((i >> 21) & 1)) b = ~b;          /* BIC/ORN/EON */
                s = shift_reg(b, i);
            }
            uint64_t res = 0;
            switch (kind) {
            case 0: res = a + s; break;
            case 1: res = a - s; break;
            case 2: res = a & s; break;
            case 3: res = a | s; break;
            default: res = a ^ s; break;
            }
            if (!sf) res &= 0xFFFFFFFF;
            if (setf) { set_nzcv(res, a, s, sf, kind == 1); if (rd(i) != 31) W(rd(i), res); }
            else W(rd(i), res);
            E.pc += 4;
            return 0;
        }
    }

    /* ---- 3-source 乘加（v19.3）：MADD/MSUB/MUL + SMADDL/SMSUBL + UMADDL/UMSUBL + SMULH/UMULH
           编码: 1 sf 0 0 1 1 0 1 1 op[3:0] Rm o0 Ra Rn Rd；op=8/9/0xD/0xA/0xE（keystone 实测） */
    if ((i & 0x1F000000) == 0x1B000000) {
        int sf = (i >> 31) & 1, op = (i >> 21) & 0xF, o0 = (i >> 15) & 1;
        int Rm = (i >> 16) & 0x1F, Ra = (i >> 10) & 0x1F, Rn = (i >> 5) & 0x1F, Rd = i & 0x1F;
        uint64_t a = RZR(Ra), n = RZR(Rn), m = RZR(Rm), res = 0;
        switch (op) {
        case 0x8: res = o0 ? a - n * m : a + n * m; break;              /* MADD/MSUB */
        case 0x9: res = o0 ? a - (int64_t)(int32_t)n * (int64_t)(int32_t)m
                           : a + (int64_t)(int32_t)n * (int64_t)(int32_t)m; break; /* SMADDL/SMSUBL */
        case 0xD: res = o0 ? a - (uint64_t)(uint32_t)n * (uint64_t)(uint32_t)m
                           : a + (uint64_t)(uint32_t)n * (uint64_t)(uint32_t)m; break; /* UMADDL/UMSUBL */
        case 0xA: res = (uint64_t)(((__int128_t)(int64_t)n * (__int128_t)(int64_t)m) >> 64); break; /* SMULH */
        case 0xE: res = (uint64_t)(((__uint128_t)n * (__uint128_t)m) >> 64); break;        /* UMULH */
        default: return unsupported(i);
        }
        if (!sf) res &= 0xFFFFFFFF;
        W(Rd, res); E.pc += 4; return 0;
    }

    /* ---- UDIV/SDIV ---- */
    if ((i & 0xFFC00000) == 0x9AC00000) {
        int sf = (i >> 31) & 1, op = (i >> 10) & 3;
        uint64_t a = RZR(rn(i)), b = RZR(rm(i)), res = 0;
        if (b == 0) res = 0;
        else if (op == 2) res = a / b;
        else if (op == 3) res = (uint64_t)((int64_t)a / (int64_t)b);
        if (!sf) res &= 0xFFFFFFFF;
        W(rd(i), res); E.pc += 4; return 0;
    }

    /* ---- 位域：BFM（0x33000000 W / 0xB3000000 X，BFI/BFXIL） ----
     * 注意：ARM 真机语义（keystone 汇编 + unicorn/qemu 实测交叉验证）：
     *   imms >= immr → BFXIL（提取）：Xd[0 : imms-immr] = Xn[immr : imms]
     *   imms <  immr → BFI（插入）：Xd[lsb : lsb+imms] = Xn[0 : imms]，lsb=(w-immr)%w
     * （v11 崩点根因：旧实现两分支语义写反，musl mallocng 的
     *   0xdde00 bfi x0,x24,#12,#52 被错执行成右移提取 → meta->maplen=0
     *   → free_group 误走 brk 分支 → get_meta(mmap页首) 读 [页首-4] → SIGBUS）
     */
    if ((i & 0xFF800000) == 0x33000000 || (i & 0xFF800000) == 0xB3000000) {
        /* v19.3: 掩码必须含符号位 bit31（0xFF800000），否则 0xB3000000 分支恒假、
           64 位 BFI/BFXIL 永不匹配（gcc/clang -Wtautological-compare 实证死分支） */
        int sf = (i >> 31) & 1, w = sf ? 64 : 32;
        int immr = (i >> 16) & 0x3F, imms = (i >> 10) & 0x3F;
        uint64_t rn_v = RZR(rn(i)), rd_v = RZR(rd(i)), res;
        if (imms >= immr) {                     /* BFXIL：提取 Xn[immr:imms] 到 Xd 低位 */
            int lsb = immr, width = imms - immr + 1;
            uint64_t mask = (width >= w) ? ~0ULL : ((1ULL << width) - 1);
            res = (rd_v & ~mask) | ((rn_v >> lsb) & mask);
        } else {                                /* BFI：Xd[lsb:lsb+imms] = Xn[0:imms]（低位插入） */
            int lsb = (w - (immr % w)) % w, width = imms + 1;
            uint64_t smask = (width >= w) ? ~0ULL : ((1ULL << width) - 1);
            uint64_t mask;
            if (lsb + width > w) mask = (smask << lsb) | (smask >> (w - lsb));
            else mask = smask << lsb;
            res = (rd_v & ~mask) | ((rn_v & smask) << lsb);
        }
        if (!sf) res &= 0xFFFFFFFF;
        W(rd(i), res); E.pc += 4; return 0;
    }

    /* ---- 位域：UBFM（0x53000000）/ SBFM（0x13000000） ---- */
    if ((i & 0x7F800000) == 0x53000000 || (i & 0x7F800000) == 0x13000000) {
        int sf = (i >> 31) & 1;
        int is_sbfm = ((i & 0x7F800000) == 0x13000000);
        int imms = (i >> 10) & 0x3F, immr = (i >> 16) & 0x3F;
        uint64_t v = RZR(rn(i)), res;
        int full = sf ? 0x3F : 0x1F;
        int R = (sf ? 64 : 32) - immr;
        if (is_sbfm && imms == full) {                  /* ASR */
            res = (sf ? (uint64_t)((int64_t)v >> immr)
                      : (uint64_t)(int32_t)((int32_t)(uint32_t)v >> immr));
        } else if (is_sbfm && imms < R) {               /* 算术位域（符号扩展） */
            int w = imms - immr + 1;
            uint64_t m = (w == (sf ? 64 : 32)) ? ~0ULL : ((1ULL << w) - 1);
            uint64_t masked = (v >> immr) & m;
            if (sf) res = (uint64_t)((int64_t)(masked << (64 - w)) >> (64 - w));
            else { int32_t st = (int32_t)((uint32_t)masked << (32 - w)) >> (32 - w); res = (uint32_t)st; }
        } else {                                        /* UBFM：LSR / UBFX / UBFIZ */
            if (imms == full) { res = v >> immr; }      /* LSR */
            else if (imms >= immr) {                    /* UBFX：提取位 immr 起 (imms-immr+1) 位 */
                int w = imms - immr + 1;
                uint64_t m = (w == (sf ? 64 : 32)) ? ~0ULL : ((1ULL << w) - 1);
                res = (v >> immr) & m;
            } else {                                    /* UBFIZ：低位 (imms+1) 位左移 (w-immr) */
                int w = imms + 1;
                uint64_t m = (w == (sf ? 64 : 32)) ? ~0ULL : ((1ULL << w) - 1);
                res = (v & m) << ((sf ? 64 : 32) - immr);
            }
            if (!sf) res &= 0xFFFFFFFF;
        }
        W(rd(i), res); E.pc += 4; return 0;
    }

    /* ---- 独占访问：LDXR/LDAXR/STXR/STLXR/LDXP/LDAXP/STXP/STLXP ----
     * 解释器单线程、无并发 → 独占必然成功：
     *   LD* = 普通读；ST* = 普通写 + 状态寄存器 Rs 写 0（成功，musl 原子循环即退出）。
     * acquire/release 位（bit15 等）在单线程下无观察差异，忽略。
     * 掩码经 capstone 对照 busybox_device 全部真实独占指令验证（15 条代码区）。 */
    if ((i & 0xFFE07C00) == 0xC8407C00 || (i & 0xFFE07C00) == 0x88407C00) {
        /* 单元素 LDXR/LDAXR */
        int sz = (i >> 30) & 3, rn = (i >> 5) & 0x1F, rt = i & 0x1F;
        uint64_t v = mem_ld(RSP(rn), 1 << sz);
        if (sz == 2) v = (uint32_t)v;
        W(rt, v); E.pc += 4; return 0;
    }
    if ((i & 0xFFE07C00) == 0xC8007C00 || (i & 0xFFE07C00) == 0x88007C00) {
        /* 单元素 STXR/STLXR：写 + Rs=0（独占成功） */
        int sz = (i >> 30) & 3, rn = (i >> 5) & 0x1F, rt = i & 0x1F, rs = (i >> 16) & 0x1F;
        mem_st(RSP(rn), RZR(rt), 1 << sz);
        W(rs, 0); E.pc += 4; return 0;
    }
    if ((i & 0xFFE00000) == 0xC8600000 || (i & 0xFFE00000) == 0x88600000) {
        /* 对 LDXP/LDAXP：读两元素 */
        int sz = (i >> 30) & 3, rn = (i >> 5) & 0x1F, rt1 = i & 0x1F, rt2 = (i >> 10) & 0x1F;
        uint64_t addr = RSP(rn);
        uint64_t v1 = mem_ld(addr, 1 << sz), v2 = mem_ld(addr + (1 << sz), 1 << sz);
        if (sz == 2) { v1 = (uint32_t)v1; v2 = (uint32_t)v2; }
        W(rt1, v1); W(rt2, v2); E.pc += 4; return 0;
    }
    if ((i & 0xFFE00000) == 0xC8200000 || (i & 0xFFE00000) == 0x88200000) {
        /* 对 STXP/STLXP：写两元素 + Ws=0 */
        int sz = (i >> 30) & 3, rn = (i >> 5) & 0x1F, rt1 = i & 0x1F, rt2 = (i >> 10) & 0x1F, rs = (i >> 16) & 0x1F;
        uint64_t addr = RSP(rn);
        mem_st(addr, RZR(rt1), 1 << sz); mem_st(addr + (1 << sz), RZR(rt2), 1 << sz);
        W(rs, 0); E.pc += 4; return 0;
    }
    /* ---- 内存屏障：DMB/DSB/ISB/CLREX（单线程解释器：无操作） ---- */
    if ((i & 0xFFFFF000) == 0xD5033000) {
        E.pc += 4; return 0;
    }

    /* ---- LDR/STR (unsigned imm / reg offset) ---- */
    {
        uint32_t m = i & 0xFFC00000;
        int sz = -1, is_ld = 0, sign = 0;
        if (m == 0x39000000) { sz = 0; }
        else if (m == 0x39400000) { sz = 0; is_ld = 1; }
        else if (m == 0x39800000) { sz = 0; is_ld = 1; sign = 1; }
        else if (m == 0x39C00000) { sz = 0; is_ld = 1; sign = 1; }   /* v19.3 LDRSB X（64位符号扩展字节加载） */
        else if (m == 0x79000000) { sz = 1; }
        else if (m == 0x79400000) { sz = 1; is_ld = 1; }
        else if (m == 0x79800000) { sz = 1; is_ld = 1; sign = 1; }
        else if (m == 0x79C00000) { sz = 1; is_ld = 1; sign = 1; }   /* v19.3 LDRSH X（64位符号扩展半字加载） */
        else if (m == 0xB9000000) { sz = 2; }
        else if (m == 0xB9400000) { sz = 2; is_ld = 1; }
        else if (m == 0xB9800000) { sz = 2; is_ld = 1; sign = 1; }
        else if (m == 0xF9000000) { sz = 3; }
        else if (m == 0xF9400000) { sz = 3; is_ld = 1; }
        else if (m == 0xF8000000) { sz = 3; }               /* STR X post */
        else if (m == 0xF8400000) { sz = 3; is_ld = 1; }    /* LDR X post */
        else if (m == 0xF8800000) { sz = 3; }               /* STR X pre */
        else if (m == 0xF8C00000) { sz = 3; is_ld = 1; }    /* LDR X pre */
        else if (m == 0xB8000000) { sz = 2; }               /* STR W post */
        else if (m == 0xB8400000) { sz = 2; is_ld = 1; }    /* LDR W post */
        else if (m == 0xB8800000) { sz = 2; }               /* STR W pre */
        else if (m == 0xB8C00000) { sz = 2; is_ld = 1; }    /* LDR W pre */
        else if (m == 0x38000000) { sz = 0; }               /* STRB post */
        else if (m == 0x38400000) { sz = 0; is_ld = 1; }    /* LDRB post */
        else if (m == 0x38800000) { sz = 0; }               /* STRB pre */
        else if (m == 0x38C00000) { sz = 0; is_ld = 1; }    /* LDRB pre */
        else if (m == 0x78000000) { sz = 1; }               /* STRH post */
        else if (m == 0x78400000) { sz = 1; is_ld = 1; }    /* LDRH post */
        else if (m == 0x78800000) { sz = 1; }               /* STRH pre */
        else if (m == 0x78C00000) { sz = 1; is_ld = 1; }    /* LDRH pre */
        /* v19: register-offset 变体（跳转表/数组访问核心；此前漏匹配 → unsupported） */
        else if (m == 0x38200000) { sz = 0; }               /* STRB reg */
        else if (m == 0x38600000) { sz = 0; is_ld = 1; }    /* LDRB reg */
        else if (m == 0x78200000) { sz = 1; }               /* STRH reg */
        else if (m == 0x78600000) { sz = 1; is_ld = 1; }    /* LDRH reg */
        else if (m == 0xB8200000) { sz = 2; }               /* STR W reg */
        else if (m == 0xB8600000) { sz = 2; is_ld = 1; }    /* LDR W reg */
        else if (m == 0xF8200000) { sz = 3; }               /* STR X reg */
        else if (m == 0xF8600000) { sz = 3; is_ld = 1; }    /* LDR X reg */
        if (sz >= 0) {
            uint64_t addr;
            if ((i >> 24) & 1) {                        /* unsigned imm */
                addr = RSP(rn(i)) + (((i >> 10) & 0xFFF) << sz);
            } else {
                int opt = (i >> 10) & 3;                /* bit11-10 */
                if (getenv("EMU_MEM")) fprintf(stderr, "  LDRSTR i=0x%08x rn=%d rm=%d rd=%d opt=%d\n", i, rn(i), rm(i), rd(i), opt);
                if (opt == 1) {                         /* post-index（imm9） */
                    int64_t imm9 = sext((i >> 12) & 0x1FF, 9);
                    addr = RSP(rn(i));
                    W(rn(i), RSP(rn(i)) + (uint64_t)imm9);
                } else if (opt == 3) {                  /* pre-index（imm9） */
                    int64_t imm9 = sext((i >> 12) & 0x1FF, 9);
                    addr = RSP(rn(i)) + (uint64_t)imm9;
                    W(rn(i), RSP(rn(i)) + (uint64_t)imm9);
                } else if (opt == 0 || opt == 2) {
                    if (!((i >> 21) & 1)) {                    /* LDUR/STUR（unscaled imm9） */
                        addr = RSP(rn(i)) + (uint64_t)sext((i >> 12) & 0x1FF, 9);
                    } else {                                   /* reg offset */
                    int option = (i >> 13) & 7;
                    int sh = (i >> 12) & 1;
                    uint64_t rmv = RZR(rm(i)), off;
                    switch (option) {
                    /* ARM64 bits[15:13]: 010=UXTW 011=LSL/UXTX 110=SXTW 111=SXTX */
                    case 2: off = (rmv & 0xFFFFFFFF) << (sh ? sz : 0); break;    /* UXTW */
                    case 3: off = sh ? (rmv << sz) : rmv; break;                 /* LSL/UXTX */
                    case 6: off = (uint64_t)(int64_t)(int32_t)(uint32_t)rmv << (sh ? sz : 0); break; /* SXTW #sh */
                    case 7: off = (uint64_t)(int64_t)rmv << (sh ? sz : 0); break;                 /* SXTX #sh */
                    default: return unsupported(i);
                    }
                    addr = RSP(rn(i)) + off;
                    }
                } else {
                    return unsupported(i);              /* 10: unprivileged 等 */
                }
            }
            if (is_ld) {
                if (getenv("EMU_MEM")) fprintf(stderr, "  LDR addr=0x%llx sz=%d rd=%d\n", (unsigned long long)addr, sz, rd(i));
                uint64_t v = mem_ld(addr, 1 << sz);
                if (sign && sz < 3) {
                    int w = 8 << sz;
                    v = (uint64_t)((int64_t)(int32_t)((uint32_t)v << (32 - w))) >> (32 - w);
                }
                if (sz == 2) v = (uint32_t)v;
                W(rd(i), v);
            } else {
                if (getenv("EMU_MEM")) fprintf(stderr, "  STR addr=0x%llx sz=%d rd=%d val=0x%llx\n", (unsigned long long)addr, sz, rd(i), (unsigned long long)RZR(rd(i)));
                mem_st(addr, RZR(rd(i)), 1 << sz);
            }
            E.pc += 4;
            return 0;
        }
    }

    /* ---- LDP/STP（X/W，含 pre/post-index） ---- */
    {
        uint32_t _m10 = ((i >> 22) & 0xFF);   /* STP/LDP：offset 0xA4/0xA5、post 0xA2/0xA3、pre 0xA6/0xA7 */
        if (!(_m10 >= 0xA2 && _m10 <= 0xA7)) goto not_ldstp;
    }
    {
        if (rd(i) == 19 && (i & 0x1F) == 19 && ((i >> 10) & 0x1F) == 20 && (i >> 31) == 1 && ((i >> 22) & 0xFF) == 0xA6)
            if (getenv("EMU_LDP")) fprintf(stderr, "[dbg] LDP/STP branch pc=%#llx insn=%08x\n", (unsigned long long)E.pc, i);
        int sf = (i >> 31) & 1, is_ld = ((i >> 22) & 1);   /* 奇数 = LDP */
        int rt = rd(i), rt2 = (i >> 10) & 0x1F;
        int64_t imm7 = sext(((i >> 15) & 0x7F), 7) * (sf ? 8 : 4);
        int pre = ((i >> 24) & 1) && ((i >> 23) & 1);   /* bit24-23=0b11 → pre */
        int post = (!((i >> 24) & 1)) && ((i >> 23) & 1); /* bit24-23=0b01 → post */
        uint64_t addr = post ? RSP(rn(i)) : (RSP(rn(i)) + (uint64_t)imm7);  /* post：读 [Rn] 后再更新 */
        (void)pre;
        if (is_ld) {
            uint64_t v1 = mem_ld(addr, sf ? 8 : 4);
            uint64_t v2 = mem_ld(addr + (sf ? 8 : 4), sf ? 8 : 4);
            if (getenv("EMU_LDP")) fprintf(stderr, "[dbg] ldp pc=%#llx addr=%#llx v1=%#llx v2=%#llx ptr1=%#llx rt=%d rt2=%d post=%d sp=%#llx x19_before=%#llx\n",
                (unsigned long long)E.pc, (unsigned long long)addr, (unsigned long long)v1, (unsigned long long)v2,
                (unsigned long long)*(uint64_t *)(uintptr_t)addr,
                rt, rt2, post, (unsigned long long)E.sp, (unsigned long long)E.r[19]);
            W(rt, v1);
            W(rt2, v2);
            if (getenv("EMU_LDP")) fprintf(stderr, "[dbg] ldp after: x19=%#llx x20=%#llx\n", (unsigned long long)E.r[19], (unsigned long long)E.r[20]);
        } else {
            if (rt == 19 && is_ld == 0 && ((i >> 22) & 0xFF) == 0xA6 && (i & 0x1F) == 19 && ((i >> 10) & 0x1F) == 20) {
                if (getenv("EMU_LDP")) fprintf(stderr, "[dbg] stp x19 pc=%#llx addr=%#llx v=%#llx sp=%#llx pre=%d post=%d\n",
                    (unsigned long long)E.pc, (unsigned long long)addr, (unsigned long long)RZR(rt), (unsigned long long)E.sp, pre, post);
                mem_st(addr, RZR(rt), 8);
                mem_st(addr + 8, RZR(rt2), 8);
                if (getenv("EMU_LDP")) fprintf(stderr, "[dbg] after: mem[addr]=%#llx mem[addr+8]=%#llx\n",
                    (unsigned long long)*(uint64_t*)(uintptr_t)addr,
                    (unsigned long long)*(uint64_t*)(uintptr_t)(addr + 8));
            } else {
                mem_st(addr, RZR(rt), sf ? 8 : 4);
                mem_st(addr + (sf ? 8 : 4), RZR(rt2), sf ? 8 : 4);
            }
            mem_st(addr, RZR(rt), sf ? 8 : 4);
            mem_st(addr + (sf ? 8 : 4), RZR(rt2), sf ? 8 : 4);
        }
        if (pre || post) W(rn(i), RSP(rn(i)) + (uint64_t)imm7);
        E.pc += 4;
        return 0;
    }

not_ldstp:
    /* ---- LDR literal ---- */
    if ((i & 0x3B000000) == 0x18000000) {                /* LDR literal（sf=bit31） */
        int sf = (i >> 31) & 1;
        uint64_t addr = E.pc + ((uint64_t)sext((i >> 5) & 0x7FFFF, 19) << 2);
        uint64_t v = mem_ld(addr, sf ? 8 : 4);
        if (!sf) v = (uint32_t)v;
        W(rd(i), v); E.pc += 4; return 0;
    }

    /* ---- MRS/MSR：TPIDR_EL0 真实读写；其他系统寄存器忽略/置 0 ---- */
    if ((i & 0xFFFFF000) == 0xD53BD000) { W(rd(i), E.tpidr); E.pc += 4; return 0; }
    if ((i & 0xFFFFF000) == 0xD51BD000) { E.tpidr = RZR(rn(i)); E.pc += 4; return 0; }
    if ((i & 0xFFF00000) == 0xD5300000) { W(rd(i), 0); E.pc += 4; return 0; }  /* 其他 MRS → 0 */
    if ((i & 0xFFF00000) == 0xD5100000) { E.pc += 4; return 0; }               /* 其他 MSR → 忽略 */
    if ((i & 0xFFFFF000) == 0xD53B0000) { W(rd(i), 0); E.pc += 4; return 0; }  /* MRS dczid_el0 → 0（禁用 dc zva 路径） */
    if ((i & 0xFFFFF01F) == 0xD50B7000) { E.pc += 4; return 0; }               /* DC ZVA → NOP（v19.3: 0xD50B7400 带 bit20 被掩码清除→恒假，改 0xD50B7000 真匹配） */

    /* ---- NEON 精简支持（musl memset/memcpy 优化） ---- */
    if ((i & 0xFFE0FC00) == 0x0F000400 || (i & 0xFFE0FC00) == 0x4F000400) {  /* MOVI vector（全零模式） */
        int cmode = (i >> 12) & 0xF, imm = (i >> 16) & 0xFF, rd = i & 0x1F;
        if (imm == 0 && cmode == 0) { E.v[rd][0] = 0; E.v[rd][1] = 0; E.pc += 4; return 0; }
        fprintf(stderr, "[emu] UNSUPPORTED movi cmode=%d imm=%d pc=%#llx\n", cmode, imm, (unsigned long long)E.pc);
        return 1;
    }
    if ((i & 0xFFE0FC00) == 0x4E000C00) {                 /* DUP vd, wn（GPR→vector） */
        int imm5 = (i >> 16) & 0x1F, rn = (i >> 5) & 0x1F, rd = i & 0x1F;
        int q = (i >> 30) & 1, elem = 0;
        if (imm5 == 1) elem = 1; else if (imm5 == 2) elem = 2;
        else if (imm5 == 4) elem = 4; else if (imm5 == 8) elem = 8;
        else if (imm5 == 16) elem = 16;
        else { fprintf(stderr, "[emu] UNSUPPORTED dup imm5=%d pc=%#llx\n", imm5, (unsigned long long)E.pc); return 1; }
        uint64_t x = 0;
        for (int k = 0; k < elem; k++) x |= (uint64_t)(uint8_t)RZR(rn) << (8 * k);
        int total = q ? 16 : 8;
        uint64_t lo = 0, hi = 0;
        for (int k = 0; k < total; k += elem) {
            if (k < 8) lo |= x << (8 * k); else hi |= x << (8 * (k - 8));
        }
        E.v[rd][0] = lo; E.v[rd][1] = hi;
        E.pc += 4; return 0;
    }
    if ((i & 0xFFE0FC00) == 0x4E003C00) {                 /* UMOV Xd, Vn.D[0] */
        W(rd(i), E.v[(i >> 5) & 0x1F][0]); E.pc += 4; return 0;
    }
    {   /* SIMD&FP 访存：str/ldr q（imm12）、stur/ldur q（imm9）、stp/ldp q（imm7） */
        uint32_t m = i & 0xFFC00000;
        if (m == 0x3D800000) {                            /* STR q（unsigned imm12，位移4） */
            uint64_t a = RSP(rn(i)) + ((((i >> 10) & 0xFFF) << 4));
            mem_st(a, E.v[rd(i)][0], 8); mem_st(a + 8, E.v[rd(i)][1], 8);
            E.pc += 4; return 0;
        }
        if (m == 0x3DC00000) {                            /* LDR q */
            uint64_t a = RSP(rn(i)) + ((((i >> 10) & 0xFFF) << 4));
            E.v[rd(i)][0] = mem_ld(a, 8); E.v[rd(i)][1] = mem_ld(a + 8, 8);
            E.pc += 4; return 0;
        }
        if (m == 0x3C800000) {                            /* STUR q（imm9 带符号） */
            uint64_t a = RSP(rn(i)) + (uint64_t)sext((i >> 12) & 0x1FF, 9);
            mem_st(a, E.v[rd(i)][0], 8); mem_st(a + 8, E.v[rd(i)][1], 8);
            E.pc += 4; return 0;
        }
        if (m == 0x3CC00000) {                            /* LDUR q */
            uint64_t a = RSP(rn(i)) + (uint64_t)sext((i >> 12) & 0x1FF, 9);
            E.v[rd(i)][0] = mem_ld(a, 8); E.v[rd(i)][1] = mem_ld(a + 8, 8);
            E.pc += 4; return 0;
        }
        if (m == 0xAD000000 || m == 0xAD800000 || m == 0xADC00000) {   /* STP q：offset/pre/post-index */
            int64_t off = sext((i >> 15) & 0x7F, 7) << 4;
            uint64_t base = RSP(rn(i));
            uint64_t a = base + (uint64_t)off;
            int rt = i & 0x1F, rt2 = (i >> 10) & 0x1F;
            if (m == 0xAD800000) a = base + (uint64_t)off;                 /* pre：addr=base+off，写回 base+off */
            else if (m == 0xADC00000) { a = base; off = 0; }               /* post：addr=base，写回 base+old_off */
            mem_st(a, E.v[rt][0], 8); mem_st(a + 8, E.v[rt][1], 8);
            mem_st(a + 16, E.v[rt2][0], 8); mem_st(a + 24, E.v[rt2][1], 8);
            if (m == 0xAD800000) W(rn(i), base + (uint64_t)off);
            else if (m == 0xADC00000) W(rn(i), base + (uint64_t)sext((i >> 15) & 0x7F, 7) * 16);
            E.pc += 4; return 0;
        }
        if (m == 0xAC000000 || m == 0xAC400000 || m == 0xAC800000 || m == 0xACC00000 || m == 0xAD400000) {   /* LDP q */
            int64_t off = sext((i >> 15) & 0x7F, 7) << 4;
            uint64_t base = RSP(rn(i));
            uint64_t a = base + (uint64_t)off;
            int rt = i & 0x1F, rt2 = (i >> 10) & 0x1F;
            if (m == 0xAC800000) a = base + (uint64_t)off;
            else if (m == 0xACC00000) { a = base; off = 0; }
            E.v[rt][0] = mem_ld(a, 8); E.v[rt][1] = mem_ld(a + 8, 8);
            E.v[rt2][0] = mem_ld(a + 16, 8); E.v[rt2][1] = mem_ld(a + 24, 8);
            if (m == 0xAC800000) W(rn(i), base + (uint64_t)off);
            else if (m == 0xACC00000) W(rn(i), base + (uint64_t)sext((i >> 15) & 0x7F, 7) * 16);
            E.pc += 4; return 0;
        }
    }

    /* ---- LD1/ST1（Advanced SIMD multiple structures，无 post-index；musl strstr 等 SWAR 路径）
           掩码：ST1=0x0C000000 / LD1=0x0C400000（bit22 区分）；寄存器数查 bit[15:12]（7=1 10=2 6=3 2=4，keystone 实测）；Q=bit30；Rn=bit[9:5]；Rt=bit[4:0] */
    {
        uint32_t _mn = i & 0x0FC00000;
        if (_mn == 0x0C000000 || _mn == 0x0C400000) {
            int is_ld = (_mn == 0x0C400000);
            int q = (i >> 30) & 1, op4 = (i >> 12) & 0xF, nreg = 0;
            if (op4 == 0x7) nreg = 1; else if (op4 == 0xA) nreg = 2;
            else if (op4 == 0x6) nreg = 3; else if (op4 == 0x2) nreg = 4;
            if (nreg) {
                uint64_t a = RSP((i >> 5) & 0x1F);
                int rt = i & 0x1F, nbytes = q ? 16 : 8;
                for (int k = 0; k < nreg; k++) {
                    int rr = (rt + k) & 0x1F;
                    if (is_ld) { E.v[rr][0] = mem_ld(a, 8); E.v[rr][1] = mem_ld(a + 8, 8); }
                    else { mem_st(a, E.v[rr][0], 8); mem_st(a + 8, E.v[rr][1], 8); }
                    a += nbytes;
                }
                E.pc += 4; return 0;
            }
        }
    }

    /* ---- CCMP/CCMN（imm：bit11-10=0b10；reg：bit11-10=0b00；cond=bit15-12，nzcv=bit3-0） ---- */
    if ((i & 0x7E400000) == 0x7A400000 || (i & 0x7E400000) == 0x3A400000) {
        int sf = (i >> 31) & 1, op = (i >> 30) & 1;      /* op=1→CCMP(sub)，0→CCMN(add) */
        int cond = (i >> 12) & 0xF, nzcv = i & 0xF;
        uint64_t a = RZR(rn(i)), b;
        if ((i & 0xC00) == 0x800) b = (i >> 16) & 0x1F;   /* imm 形式 */
        else b = RZR((i >> 16) & 0x1F);                   /* reg 形式 */
        if (cond_true(cond)) {
            uint64_t res = op ? (a - b) : (a + b);
            set_nzcv(res, a, b, sf, op);
        } else {
            E.nzcv = (uint32_t)nzcv << 28;
        }
        E.pc += 4; return 0;
    }

    /* ---- CSEL/CSINC/CSINV/CSNEG ---- (CSEL/CSINC=0x1A800000 系 op=00；CSINV/CSNEG=0x5A800000 系 op=10；op2: 00=base/01=inc/neg；SDIV/UDIV 的 op2=11 由 op 位排除) */
    if ((i & 0xFFE00000) == 0x1A800000 || (i & 0xFFE00000) == 0x5A800000 ||
        (i & 0xFFE00000) == 0x9A800000 || (i & 0xFFE00000) == 0xDA800000) {
        int op = (i >> 21) & 3;           /* 00=CSEL/CSINC  10=CSINV/CSNEG */
        int op2 = (i >> 10) & 3;          /* 00=base 01=inc/neg */
        int c = (i >> 12) & 0xF;          /* v19.2 修复：CSEL 条件码在 bit[15:12]（原 i&0xF 误取 Rd 低位） */
        uint64_t a = RZR(rn(i)), b = RZR(rm(i));
        int t = cond_true(c);
        uint64_t res;
        if (op == 0) {
            if (op2 == 1) res = t ? a : (b + 1);
            else res = t ? a : b;
        } else {
            if (op2 == 1) res = t ? a : (~b + 1);
            else res = t ? a : ~b;
        }
        W(rd(i), res); E.pc += 4; return 0;
    }

    /* ---- CLZ ---- (0x5AC01000/0xDAC01000 系，前导零) */
    if ((i & 0xFFFFFC00) == 0x5AC01000 || (i & 0xFFFFFC00) == 0xDAC01000) {
        int sf = (i >> 31) & 1;
        uint64_t v = E.r[rn(i)];
        int r;
        if (sf) r = v ? __builtin_clzll(v) : 64;
        else r = (uint32_t)v ? __builtin_clz((uint32_t)v) : 32;
        W(rd(i), (uint64_t)r); E.pc += 4; return 0;
    }

    /* ---- RBIT ---- (0x5AC00000/0xDAC00000 系，位反转；bit15-10=000000 与 CLZ 区分) */
    if ((i & 0xFFFFFC00) == 0x5AC00000 || (i & 0xFFFFFC00) == 0xDAC00000) {
        int sf = (i >> 31) & 1;
        uint64_t v = E.r[rn(i)], r = 0;
        int k;
        for (k = 0; k < (sf ? 64 : 32); k++) { r = (r << 1) | (v & 1); v >>= 1; }
        W(rd(i), r); E.pc += 4; return 0;
    }

    /* ---- SDIV/UDIV + LSLV/LSRV/ASRV/RORV ---- (0x1AC/0x9AC 系；bit13=1→variable shift，bit13=0→div) */
    if ((i & 0xFFE00000) == 0x1AC00000 || (i & 0xFFE00000) == 0x9AC00000) {
        int sf = (i >> 31) & 1;
        int bit13 = (i >> 13) & 1;
        int op2 = (i >> 10) & 3;
        if (bit13) {
            uint64_t v = E.r[rn(i)], n = E.r[rm(i)] & (sf ? 63 : 31);
            uint64_t r;
            switch (op2) {
            case 0: r = v << n; break;                          /* LSLV */
            case 1: r = v >> n; break;                          /* LSRV */
            case 2: r = (uint64_t)((int64_t)v >> n); break;     /* ASRV */
            default: /* RORV */
                if (n == 0) r = v;
                else r = (v >> n) | (v << ((sf ? 64 : 32) - n));
                break;
            }
            if (!sf) r &= 0xFFFFFFFF;
            W(rd(i), r); E.pc += 4; return 0;
        } else {
            uint64_t a = E.r[rn(i)], b = E.r[rm(i)];
            int64_t r;
            if (op2 == 3) r = b ? (int64_t)((int64_t)a / (int64_t)b) : 0;   /* SDIV */
            else r = b ? (int64_t)(a / b) : 0;                              /* UDIV */
            if (!sf) r = (int32_t)r;
            W(rd(i), (uint64_t)r); E.pc += 4; return 0;
        }
    }

    return unsupported(i);
}

int emu_run(uint64_t entry, uint64_t sp) {
    memset(&E, 0, sizeof(E));
    E.pc = entry;
    E.sp = sp;
    g_emu_active = 1;
    if (setjmp(g_emu_jmp) != 0) {
        fprintf(stderr, "[emu] mem fault @ pc=0x%llx (longjmp exit) x0=0x%llx sp=0x%llx x1=0x%llx x2=0x%llx x19=0x%llx x20=0x%llx x21=0x%llx x23=0x%llx x24=0x%llx x30=0x%llx x6=0x%llx x16=0x%llx x17=0x%llx x22=0x%llx x25=0x%llx\n",
                (unsigned long long)E.pc,
                (unsigned long long)E.r[0], (unsigned long long)E.sp,
                (unsigned long long)E.r[1], (unsigned long long)E.r[2],
                (unsigned long long)E.r[19], (unsigned long long)E.r[20],
                (unsigned long long)E.r[21], (unsigned long long)E.r[23],
                (unsigned long long)E.r[24], (unsigned long long)E.r[30],
                (unsigned long long)E.r[6], (unsigned long long)E.r[16],
                (unsigned long long)E.r[17], (unsigned long long)E.r[22],
                (unsigned long long)E.r[25]);
        tr_dump();
        g_emu_active = 0;
        return E.exit_code ? (int)E.exit_code : -EFAULT;
    }
    unsigned long long steps = 0;
    while (!E.exited) {
        if (exec_one()) break;
        if (++steps > 500000000ULL) {
            fprintf(stderr, "[emu] STEP LIMIT pc=0x%llx\n", (unsigned long long)E.pc);
            E.exited = 1; E.exit_code = -ETIMEDOUT;
        }
    }
    g_emu_active = 0;
    fprintf(stderr, "[emu] exit code=%ld steps=%llu pc=0x%llx\n",
            E.exit_code, steps, (unsigned long long)E.pc);
    return (int)E.exit_code;
}

int emu_is_active(void) { return g_emu_active; }
jmp_buf *emu_jmp_buf(void) { return &g_emu_jmp; }
void emu_deactivate(void) { g_emu_active = 0; }

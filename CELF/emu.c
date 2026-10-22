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
#include <math.h>

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
    if (n == 31) E.sp = v; else if (n < 31) E.r[n] = v;
}

static uint64_t tb_last[40]; static int tb_pos = 0;
static uint32_t fetch(void) {
    uint32_t insn = 0;
    /* v19.18j: 合法取指区 = 主程序区 + interp 区（动态 ELF 的 ld-musl 在独立基址） */
    extern uintptr_t g_interp_base;
    extern size_t g_interp_size;
    int ok = (E.pc >= g_base && E.pc + 4 <= g_base + g_total_size) ||
             (g_interp_base && E.pc >= g_interp_base && E.pc + 4 <= g_interp_base + g_interp_size);
    if (ok) {
        memcpy(&insn, (void *)(uintptr_t)E.pc, 4);
    } else {
        fprintf(stderr, "[emu] last pcs:");
        for (int k = 0; k < 40; k++) { int idx = (tb_pos - 40 + k) & 39; if (tb_last[idx]) fprintf(stderr, " 0x%lx", (unsigned long)tb_last[idx]); }
        fprintf(stderr, "\n");
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
    int sf = (i >> 31) & 1;
    if (!sf) {
        uint32_t w = (uint32_t)v;
        switch (sh) {
        case 0: return (uint64_t)(uint32_t)(w << amt);
        case 1: return (uint64_t)(uint32_t)(w >> amt);
        case 2: return (int64_t)(int32_t)((int32_t)w >> amt);
        default: return (uint64_t)(uint32_t)(amt ? (w >> amt) | (w << (32 - amt)) : w);
        }
    }
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

/* v19.12: guest 0x580000 写缓冲区透明重定向。
   原始链接布局把 stdout 等写缓冲固定在 guest 0x580000；宿主 base+0x580000
   可能被宿主进程占用（NOREPLACE 失败）→ MAP_FIXED 覆盖会弄崩宿主退出。
   这里把该 guest 区访存重定向到 elf-runner 提供的安全匿名区（g_580_redirect）。
   0x580000 区为纯写缓冲（零初始化），重定向后读 0 语义不变。 */
extern uint64_t g_580_redirect;   /* 安全区基址，0=未启用 */
static void *mem_p(uint64_t a) {
    if (g_580_redirect && a >= (uint64_t)g_base + 0x580000 &&
        a < (uint64_t)g_base + 0x590000)
        return (void *)(uintptr_t)(g_580_redirect + (a - ((uint64_t)g_base + 0x580000)));
    return (void *)(uintptr_t)a;
}
static uint64_t mem_ld(uint64_t a, int bytes) {
    void *p = mem_p(a);
    switch (bytes) {
    case 1: return *(uint8_t *)p;
    case 2: { uint16_t v; memcpy(&v, p, 2); return v; }
    case 4: { uint32_t v; memcpy(&v, p, 4); return v; }
    default:{ uint64_t v; memcpy(&v, p, 8); return v; }
    }
}
static double fp_ld(int n, int type) {
    double d; uint64_t bits = E.v[n][0];
    if (!type) { float f; memcpy(&f, &bits, 4); return (double)f; }
    memcpy(&d, &bits, 8); return d;
}
static void fp_st(int n, int type, double v) {
    if (!type) { float f = (float)v; uint32_t b; memcpy(&b, &f, 4); E.v[n][0] = b; E.v[n][1] = 0; }
    else { uint64_t b; memcpy(&b, &v, 8); E.v[n][0] = b; E.v[n][1] = 0; }
}
static void mem_st(uint64_t a, uint64_t v, int bytes) {
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
static int g_fgetc_trace = 0;  /* v19.17.1 探针：fgetc 死循环（FGETC_TRACE=1） */
static int exec_one(void) {
    /* v11: 每条指令进 ring buffer（崩点带出最后 64 条） */
    extern uintptr_t g_interp_base;
    extern size_t g_interp_size;
    int insn_ok = (E.pc >= g_base && E.pc + 4 <= g_base + g_total_size) ||
                  (g_interp_base && E.pc >= g_interp_base && E.pc + 4 <= g_interp_base + g_interp_size);
    tr_record(E.pc, insn_ok
                  ? *(const uint32_t *)(uintptr_t)E.pc : 0);
    if (g_iotrace)
        fprintf(stderr, "[it] pc-off=0x%llx insn=0x%08x\n",
                (unsigned long long)(E.pc - g_base),
                (unsigned int)(insn_ok
                    ? *(const uint32_t *)(uintptr_t)E.pc : 0));

    uint32_t i = fetch();
    if (E.exited) return 1;
    tb_last[tb_pos & 39] = E.pc; tb_pos++;
    if ((i & 0xFF000000) == 0x94000000 || (i & 0xFF000000) == 0xD6000000 ||
        (i & 0xFF000000) == 0x14000000 || (i & 0x7FE00000) == 0x54000000)
        { tb_last[tb_pos & 39] = 0; }
    /* v19.18j 打点：interp 内 0x1fd00（__init_tls 入口）——TLS 结构指针来源 */
    extern uintptr_t g_interp_base;
    { static int tm_n = 0;
      static int tzscan_n;
      static int tzc_n;
      static int tzl_n;
      static int tzm_n;
    }
    if (g_fgetc_trace) {
        uint64_t po = E.pc - g_base;
    }
    if (g_base) {
        uint64_t po = E.pc - g_base;
    }
    if (g_base) {
        uint64_t po = E.pc - g_base;
    }
    if (g_base) {
        uint64_t po = E.pc - g_base;
        static int c_05c, c_080, c_084, c_088, c_190, c_334, c_554, c_3a8, c_fzf, c_158, c_358;
        if (g_base) {
            uint64_t po = E.pc - g_base;
            if (po == 0x8f05c) c_05c++;
            if (po == 0x8f080) c_080++;
            if (po == 0x8f088) c_088++;
            if (po == 0x8f190) c_190++;
            if (po == 0x8334) c_334++;
            if (po == 0x8554) c_554++;
            if (po == 0x83a8) c_3a8++;
        }
    }
    if (g_base) {
        uint64_t po = E.pc - g_base;
    }
    if (g_base) {
        uint64_t po = E.pc - g_base;
    }
    if (g_base) {
        uint64_t po = E.pc - g_base;
    }
    if (g_base) {
        uint64_t po = E.pc - g_base;
    }
    if (g_base) {
        uint64_t po = E.pc - g_base;
    }
    if (g_base) {
        uint64_t po = E.pc - g_base;
    }
    if (g_base) {
        uint64_t po = E.pc - g_base;
    }
    if (g_base) {
        uint64_t po = E.pc - g_base;
    }
    if (g_base) {
        uint64_t po = E.pc - g_base;
    }
                /* ---- SVC ---- */
    if ((i & 0xFF000000) == 0xD4000000) {
        /* aarch64 Linux ABI: syscall nr 在 x8（musl 裸 svc 直接 mov x8,nr;
           musl __syscall 封装也是 mov x8,x16 后再 svc，x8 恒为真值） */
        uint64_t nr = E.r[8];
        if (nr == 0 && E.r[16] != 0) nr = E.r[16];   /* 兜底：部分旧封装只放 x16 */
        uint64_t ret = translate_syscall(nr, E.r[0], E.r[1], E.r[2],
                                         E.r[3], E.r[4], E.r[5]);
        if (g_emu_halt) { E.exited = 1; E.exit_code = (int)g_exit_code; }
        E.r[0] = (uint64_t)ret;
        E.pc += 4;
        return 0;
    }

    /* ---- NOP / 屏障 / 缓存维护 / SYS ---- */
    if (i == 0xD503201F) { E.pc += 4; return 0; }
    if ((i & 0xFFFFF01F) == 0xD503301F) { E.pc += 4; return 0; }   /* DMB/DSB/ISB */
    if ((i & 0xFFF80000) == 0xD5000000) { E.pc += 4; return 0; }   /* SYS/DC/IC/AT */

    /* ---- 分支 ---- */
    if ((i & 0xFF800000) == 0x52800000) {                 /* MOVZ W（临时：0xf3514 轨迹） */
    }
    if ((i & 0x7C000000) == 0x14000000) {                 /* B/BL（bit31=1 是 BL） */
        uint64_t tgt = E.pc + ((uint64_t)sext(i & 0x03FFFFFF, 26) << 2);
        if ((i >> 31) & 1) E.r[30] = E.pc + 4;
        E.pc = tgt;
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
        uint64_t oldpc = E.pc;
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
               ADD/SUB（无 S）Rn=31 → SP；ADDS/SUBS/逻辑 → ZR。
               ★ v19.19：CMP/CMN（SUBS/ADDS 且 Rd=31）的 Rn=31 语义是 SP——
               musl/GCC stack-clash 探测用 cmp sp,x2（0xeb2263ff），误读 ZR 导致
               nzcv 全错 → b.eq 不跳 → sp 减穿未映射区。 */
            int is_ext = !is_logic && ((i >> 21) & 1);
            uint64_t a;
            if (setf && rd(i) == 31 && rn(i) == 31) a = RSP(rn(i));   /* CMP/CMN: Rn=31=SP */
            else a = (is_ext && !setf) ? RSP(rn(i)) : RZR(rn(i));
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

    /* ---- UDIV/SDIV ----（bit13=0 才是 div；bit13=1 是 LSLV/LSRV/ASRV/RORV，
       由下方 variable-shift 块处理——之前掩码 0xFFC00000 误捕 ASRV（0x9AC02xxx），
       strftime 0xf3220 的 asr x0,x26,x0 被当 udiv → date %H 空输出） */
    if ((i & 0xFFC00000) == 0x9AC00000 && !((i >> 13) & 1)) {
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
        /* v19.11: LDRSB/LDRSH reg-offset（bit26=1）。此前 LDRSB W reg 的
           m==0x38C00000 被误当 PRFM 无操作 → od 宽度表读 0 → sdiv 除零死循环 */
        if ((i & 0xFFE00000) == 0x38E00000) { sz = 0; is_ld = 1; sign = 1; }  /* LDRSB W reg */
        else if ((i & 0xFFE00000) == 0x39E00000) { sz = 0; is_ld = 1; sign = 1; }  /* LDRSB X reg */
        else if ((i & 0xFFE00000) == 0x7AE00000) { sz = 1; is_ld = 1; sign = 1; }  /* LDRSH W reg */
        else if ((i & 0xFFE00000) == 0x7FE00000) { sz = 1; is_ld = 1; sign = 1; }  /* LDRSH X reg */
        else if (m == 0x39000000) { sz = 0; }
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
        else if (m == 0xB8800000) { sz = 2; is_ld = 1; sign = 1; } /* v19.7 LDURSW（原错标 STR W pre） */
        else if (m == 0xB8C00000) { sz = 2; }               /* 保留位组合 → 保守无操作 */
        else if (m == 0x38000000) { sz = 0; }               /* STRB post */
        else if (m == 0x38400000) { sz = 0; is_ld = 1; }    /* LDRB post */
        else if (m == 0x38800000) { sz = 0; is_ld = 1; sign = 1; } /* LDURSB X（64位符号扩展） */
        else if (m == 0x38C00000) { sz = 0; is_ld = 1; sign = 1; } /* v19.18h2 LDURSB W（原错标 PRFM 无操作 → 被当 STRB 写！find fnmatch 破坏字符串根因） */
        else if (m == 0x78000000) { sz = 1; }               /* STRH post */
        else if (m == 0x78400000) { sz = 1; is_ld = 1; }    /* LDRH post */
        else if (m == 0x78800000) { sz = 1; is_ld = 1; sign = 1; } /* LDURSH X（64位符号扩展） */
        else if (m == 0x78C00000) { sz = 1; is_ld = 1; sign = 1; } /* v19.18h2 LDURSH W（原错标 PRFM 无操作 → 被当 STRH 写） */
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
                uint64_t v = mem_ld(addr, 1 << sz);
                if (sign && sz < 3) {
                    int w = 8 << sz;
                    v = (uint64_t)((int64_t)(int32_t)((uint32_t)v << (32 - w))) >> (32 - w);
                }
                if (sz == 2 && !sign) v = (uint32_t)v;
                W(rd(i), v);
            } else {
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
            W(rt, v1);
            W(rt2, v2);
        } else {
            if (rt == 19 && is_ld == 0 && ((i >> 22) & 0xFF) == 0xA6 && (i & 0x1F) == 19 && ((i >> 10) & 0x1F) == 20) {
                mem_st(addr, RZR(rt), 8);
                mem_st(addr + 8, RZR(rt2), 8);
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
    if ((i & 0xFFFFF000) == 0xD53BD000) {
        if (getenv("TPIDR_TRACE")) fprintf(stderr, "[tpidr] mrs x%d <- 0x%lx\n", rd(i), (unsigned long)E.tpidr);
        W(rd(i), E.tpidr); E.pc += 4; return 0;
    }
    if ((i & 0xFFFFF000) == 0xD51BD000) {
        /* v19.18k：msr tpidr_el0 的 Rt 在 bit[4:0]（=rd(i)），不是 bit[9:5]——
           之前用 rn(i) 把 x2 的垃圾值写进 tpidr，__dls2 的 stur [tpidr-0xb0] 崩。 */
        int rt = (int)(i & 31);
        if (getenv("TPIDR_TRACE")) fprintf(stderr, "[tpidr] msr tpidr_el0 <- x%d = 0x%lx (lr=0x%lx pc=0x%lx)\n",
                                          rt, (unsigned long)RZR(rt), (unsigned long)E.r[30], (unsigned long)E.pc);
        E.tpidr = RZR(rt); E.pc += 4; return 0;
    }
    if ((i & 0xFFF00000) == 0xD5300000) { W(rd(i), 0); E.pc += 4; return 0; }  /* 其他 MRS → 0 */
    if ((i & 0xFFF00000) == 0xD5100000) { E.pc += 4; return 0; }               /* 其他 MSR → 忽略 */
    if ((i & 0xFFFFF000) == 0xD53B0000) { W(rd(i), 0); E.pc += 4; return 0; }  /* MRS dczid_el0 → 0（禁用 dc zva 路径） */
    if ((i & 0xFFFFF01F) == 0xD50B7000) { E.pc += 4; return 0; }               /* DC ZVA → NOP（v19.3: 0xD50B7400 带 bit20 被掩码清除→恒假，改 0xD50B7000 真匹配） */

    /* ---- SIMD/Scalar 移位 by immediate：SHL（逻辑左移）/ SSHR（算术右移） ----
       scalar d:   0x5F 前缀（busybox 0xF663C scalbn 的 shl d1,d1,#52）
       vector:     0x4F/0x0F 前缀（v.2d/v.4s/v.2s/v.8b）
       imm 解码（keystone 实测）：imm = immh5 + (q<<5)，q=bit21；esize 由 immh5 最高位定
       SSHR 右移量 = esize*2 - immh5（8b:16-10=6；2d:64-19=45 实测） */
    if ((i & 0xFF000000) == 0x5F000000 && ((i >> 22) & 3) == 1) {  /* scalar D SHL */
        int Rd = i & 0x1F, Rn = (i >> 5) & 0x1F;
        int imm = ((i >> 16) & 0x1F) + (((i >> 21) & 1) << 5);
        E.v[Rd][0] = E.v[Rn][0] << imm;
        E.v[Rd][1] = 0;
        E.pc += 4; return 0;
    }
    if ((i & 0xFE000000) == 0x4E000000) {  /* vector SHL/SSHR by imm（Q 含 0/1） */
        int Rd = i & 0x1F, Rn = (i >> 5) & 0x1F;
        int immh5 = (i >> 16) & 0x1F, q = (i >> 21) & 1;
        int imm = immh5 + (q << 5);
        if ((i & 0x0060FC00) == 0x00400000) {  /* 0x1F 类 SHL（immb=0x15 模式，bit10-15） */
            int esize;
            if (immh5 & 0x10) esize = 64;
            else if (immh5 & 0x08) esize = 32;
            else if (immh5 & 0x04) esize = 16;
            else esize = 8;
            switch (esize) {
            case 64: E.v[Rd][0] = E.v[Rn][0] << imm; E.v[Rd][1] = E.v[Rn][1] << imm; break;
            case 32: {
                int n = esize / 32;
                for (int e = 0; e < (q ? 4 : 2); e++)
                    E.v[Rd][e] = (uint32_t)((uint32_t)E.v[Rn][e] << imm);
                break;
            }
            case 16: {
                for (int e = 0; e < (q ? 8 : 4); e++) {
                    uint16_t u = (uint16_t)E.v[Rn][e];
                    E.v[Rd][e] = (uint16_t)(u << imm);
                }
                break;
            }
            default: {
                for (int e = 0; e < (q ? 16 : 8); e++) {
                    uint8_t u = (uint8_t)E.v[Rn][e];
                    E.v[Rd][e] = (uint8_t)(u << imm);
                }
                break;
            }
            }
            E.pc += 4; return 0;
        }
        if ((i & 0x0060FC00) == 0x00000000 && immh5) {  /* SSHR（bit15-10=0，immb=0） */
            int esize;
            if (immh5 & 0x10) esize = 64;
            else if (immh5 & 0x08) esize = 32;
            else if (immh5 & 0x04) esize = 16;
            else esize = 8;
            int sh = esize * 2 - immh5;
            switch (esize) {
            case 64: E.v[Rd][0] = (uint64_t)((int64_t)E.v[Rn][0] >> sh); E.v[Rd][1] = (uint64_t)((int64_t)E.v[Rn][1] >> sh); break;
            case 32: { int n = esize / 32; for (int e = 0; e < (q ? 4 : 2); e++) E.v[Rd][e] = (uint32_t)((int32_t)E.v[Rn][e] >> sh); break; }
            case 16: { for (int e = 0; e < (q ? 8 : 4); e++) E.v[Rd][e] = (uint16_t)((int16_t)E.v[Rn][e] >> sh); break; }
            default: { for (int e = 0; e < (q ? 16 : 8); e++) E.v[Rd][e] = (uint8_t)((int8_t)E.v[Rn][e] >> sh); break; }
            }
            E.pc += 4; return 0;
        }
    }

    /* ---- NEON 精简支持（musl memset/memcpy 优化） ---- */
    if ((i & 0xFFE0FC00) == 0x0F000400 || (i & 0xFFE0FC00) == 0x4F000400 ||  /* MOVI/MVNI 2S/4S */
        (i & 0xFFE0FC00) == 0x0F008400 || (i & 0xFFE0FC00) == 0x4F008400 ||  /* MOVI/MVNI 4H/8H */
        (i & 0xFFE0FC00) == 0x0F00E400 || (i & 0xFFE0FC00) == 0x4F00E400 ||  /* MOVI 8B/16B */
        (i & 0xFFE0FC00) == 0x6F00E400 ||                                     /* MOVI 2D（imm8=0 或 0xFF） */
        (i & 0xFFE0FC00) == 0x2F00E400 ||                                     /* MOVI D（64 位标量零/FF） */
        (i & 0xFFE0FC00) == 0x2F000400 || (i & 0xFFE0FC00) == 0x6F000400 ||  /* MVNI 2S/4S */
        (i & 0xFFE0FC00) == 0x2F008400 || (i & 0xFFE0FC00) == 0x6F008400 ||  /* MVNI 4H/8H */
        (i & 0xFFE0FC00) == 0x0F00A400 || (i & 0xFFE0FC00) == 0x4F00A400) {  /* MOVI H lsl #8 */
        int cmode = (i >> 12) & 0xF;
        int q = (i >> 30) & 1;
        int rd = i & 0x1F;
        int mvni = ((i >> 29) & 1) && cmode != 14;   /* op 位=1 且非 2D 特例 → MVNI */
        int imm8 = ((i >> 16) & 0x7) << 5 | ((i >> 5) & 0x1F);
        uint64_t v = 0;
        if (cmode == 14) {                          /* 8B/16B/2D：imm8 复制 8 次 */
            v = (uint64_t)(uint8_t)imm8 * 0x0101010101010101ull;
        } else if (cmode == 8) {                    /* 4H/8H：imm8 复制 2 次到 16 位，4 个半字 */
            uint64_t h = (uint64_t)(uint8_t)imm8 * 0x0101ull;
            v = h * 0x0001000100010001ull;
        } else if (cmode == 0) {                    /* 2S/4S：imm8 复制 4 次到 32 位，2 个字 */
            uint64_t w = (uint64_t)(uint8_t)imm8 * 0x01010101ull;
            v = w * 0x0000000100000001ull;
        } else if (cmode == 2) {                    /* 2S/4S lsl #8 */
            v = (uint64_t)((uint32_t)(uint8_t)imm8 << 8) * 0x0000000100000001ull;
        } else if (cmode == 4) {                    /* 2S/4S lsl #16 */
            v = (uint64_t)((uint32_t)(uint8_t)imm8 << 16) * 0x0000000100000001ull;
        } else if (cmode == 6) {                    /* 2S/4S lsl #24 */
            v = (uint64_t)((uint32_t)(uint8_t)imm8 << 24) * 0x0000000100000001ull;
        } else if (cmode == 10) {                   /* 8H lsl #8 */
            uint64_t h = (uint64_t)((uint16_t)(uint8_t)imm8 << 8);
            v = h * 0x0001000100010001ull;
        } else {
            fprintf(stderr, "[emu] UNSUPPORTED movi cmode=%d pc=%#llx\n", cmode, (unsigned long long)E.pc);
            return 1;
        }
        if (mvni) v = ~v;
        if (q) { E.v[rd][0] = v; E.v[rd][1] = v; }
        else { E.v[rd][0] = v; E.v[rd][1] = 0; }
        E.pc += 4; return 0;
    }
    /* ---- SSHLL/USHLL 长型扩展左移（memchr/strstr/tre literal 向量） ----
           v19.20：immh→sesize 映射 1→8/2→16/4→32/8→64（原实现顺序写反），
           desize=sesize*2，nelem=128/desize；Q=0 读 Vn 低 64、Q=1 读高 64；目的恒为 128 位视图。
           immb=shift。修复 0x4b694 str q31 装载错位（锚 ^/$ 与字面量内存污染根因）。 */
    if ((i & 0x8F80F000) == 0x0F00A000) {
        int immh = (i >> 19) & 0xF, immb = (i >> 16) & 0xF, q = (i >> 30) & 1;
        int is_sshll = ((i >> 29) & 1) == 0;   /* U=0: SSHLL 符号扩展；U=1: USHLL 零扩展 */
        int sesize = 0;
        if (immh == 1) sesize = 8; else if (immh == 2) sesize = 16;
        else if (immh == 4) sesize = 32; else if (immh == 8) sesize = 64;
        if (sesize == 0) { fprintf(stderr, "[emu] SSHLL immh=%d unhandled pc=%llx\n", immh, (unsigned long long)E.pc); E.pc += 4; return 0; }
        int desize = sesize * 2, nelem = 128 / desize;
        uint64_t srclo = q ? E.v[rn(i)][1] : E.v[rn(i)][0];
        E.v[rd(i)][0] = 0; E.v[rd(i)][1] = 0;   /* 覆盖，勿残留高位 */
        for (int k = 0; k < nelem; k++) {
            uint64_t el = (srclo >> (k * sesize)) & ((1ULL << sesize) - 1);
            if (is_sshll && (el & (1ULL << (sesize - 1))))
                el |= ~((1ULL << sesize) - 1);  /* 符号扩展至 64 位 */
            E.v[rd(i)][(k * desize) >> 6] |= (el << immb) << ((k * desize) & 63);
        }
        E.pc += 4; return 0;
    }
    /* ---- INS vD.elem, Rn（mov vD.b/h/s/d[l], wN/xN）grep/memchr 向量路径 ---- */
    if ((i & 0xFFE0FC00) == 0x4E001C00) {
        int esz = (i >> 22) & 3, idx = (i >> 16) & 0xF, rn = (i >> 5) & 0x1F;
        int q = (i >> 30) & 1;
        if (esz == 0) { int l = idx & 7; E.v[rd(i)][l >> 3] = (E.v[rd(i)][l >> 3] & ~(0xFFULL << ((l & 7) << 3))) | ((uint64_t)(uint8_t)RZR(rn) << ((l & 7) << 3)); }
        else if (esz == 1) { int l = idx & 3; E.v[rd(i)][l >> 2] = (E.v[rd(i)][l >> 2] & ~(0xFFFFULL << ((l & 3) << 4))) | ((uint64_t)(uint16_t)RZR(rn) << ((l & 3) << 4)); }
        else if (esz == 2) { int l = idx & 1; E.v[rd(i)][l] = (E.v[rd(i)][l] & ~0xFFFFFFFFULL) | (uint32_t)RZR(rn); }
        else { if (q) E.v[rd(i)][1] = RZR(rn); else E.v[rd(i)][0] = RZR(rn); }
        E.pc += 4; return 0;
    }
    /* ---- SIMD&FP 双寄存器对访存：STP/LDP S/D/Q（seq 的 ldp d19,d20 等） ---- */
    if ((i & 0x3FC00000) == 0x2D000000 || (i & 0x3FC00000) == 0x2C000000 ||
        (i & 0x3FC00000) == 0x2D400000 || (i & 0x3FC00000) == 0x2C400000) {
        int is_ld = (i >> 22) & 1;                   /* bit22: 1=LDP/LDNP, 0=STP/STNP */
        int opc = (i >> 30) & 3;                     /* 00=S 01=D 10=Q */
        int size = opc == 0 ? 4 : opc == 1 ? 8 : 16; /* S=4B D=8B Q=16B */
        int scale = size == 4 ? 2 : size == 8 ? 3 : 4;
        int64_t imm = (int64_t)sext((i >> 15) & 0x7F, 7) << scale;
        /* bit[23:22]: 00=STP-offset 01=LDP-offset 10=pre/post 11=pre/post；bit23=1 写回，pre/post 由 bit24 分（1=pre 0=post） */
        uint64_t base = RSP(rn(i)), addr;
        if ((i >> 23) & 1) {
            if ((i >> 24) & 1) { addr = base + (uint64_t)imm; W(rn(i), addr); }  /* pre */
            else { addr = base; W(rn(i), base + (uint64_t)imm); }                 /* post */
        } else addr = base + (uint64_t)imm;
        int rt = rd(i), rt2 = (i >> 10) & 0x1F;
        if (is_ld) {
            if (size == 16) {
                E.v[rt][0] = mem_ld(addr, 8); E.v[rt][1] = mem_ld(addr + 8, 8);
                E.v[rt2][0] = mem_ld(addr + 16, 8); E.v[rt2][1] = mem_ld(addr + 24, 8);
            } else if (size == 8) {
                E.v[rt][0] = mem_ld(addr, 8); E.v[rt][1] = 0;
                E.v[rt2][0] = mem_ld(addr + 8, 8); E.v[rt2][1] = 0;
            } else {
                E.v[rt][0] = (uint32_t)mem_ld(addr, 4); E.v[rt][1] = 0;
                E.v[rt2][0] = (uint32_t)mem_ld(addr + 4, 4); E.v[rt2][1] = 0;
            }
        } else {
            if (size == 16) {
                mem_st(addr, E.v[rt][0], 8); mem_st(addr + 8, E.v[rt][1], 8);
                mem_st(addr + 16, E.v[rt2][0], 8); mem_st(addr + 24, E.v[rt2][1], 8);
            } else if (size == 8) {
                mem_st(addr, E.v[rt][0], 8); mem_st(addr + 8, E.v[rt2][0], 8);
            } else {
                mem_st(addr, E.v[rt][0] & 0xFFFFFFFF, 4); mem_st(addr + 4, E.v[rt2][0] & 0xFFFFFFFF, 4);
            }
        }
        E.pc += 4; return 0;
    }
    if ((i & 0x0F20FC00) == 0x0E201C00) {                 /* ORR (vector)：Vd = Vn | Vm（8B/16B，含 mov 特例） */
        int rd = i & 0x1F, rn = (i >> 5) & 0x1F, rm = (i >> 16) & 0x1F, q = (i >> 30) & 1;
        E.v[rd][0] = E.v[rn][0] | E.v[rm][0];
        E.v[rd][1] = q ? (E.v[rn][1] | E.v[rm][1]) : 0;
        E.pc += 4; return 0;
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
    /* ---- 标量 FP 访存（B/H/S/D 元素）---- */
    if ((i & 0x7FC00000) == 0x3D000000 || (i & 0x7FC00000) == 0x7D000000 ||
        (i & 0x7FC00000) == 0xBD000000 || (i & 0x7FC00000) == 0xFD000000 ||
        (i & 0x7FC00000) == 0x3C000000 || (i & 0x7FC00000) == 0x7C000000 ||
        (i & 0x7FC00000) == 0xBC000000 || (i & 0x7FC00000) == 0xFC000000 ||
        (i & 0x7FC00000) == 0x3D400000 || (i & 0x7FC00000) == 0x7D400000 ||
        (i & 0x7FC00000) == 0xBD400000 || (i & 0x7FC00000) == 0xFD400000 ||
        /* v19.18f: opc=1（LDUR B/H/S/D）编码 bit22=1——awk 内部解释器用 LDUR D */
        (i & 0x7FC00000) == 0x3C400000 || (i & 0x7FC00000) == 0x7C400000 ||
        (i & 0x7FC00000) == 0xBC400000 || (i & 0x7FC00000) == 0xFC400000) {
        int sz = ((i >> 31) & 1) << 1 | ((i >> 30) & 1);  /* B=0 H=1 S=2 D=3 */
        int rd = i & 0x1F, opc = (i >> 22) & 3;
        int nbytes = 1 << sz;
        if (i & 0x00200000) {                             /* bit21=1：寄存器偏移 str/ldr b/h/s/d, [xn, xm, <ext>]（v19.17.1 修正：原先判 imm12 误吞 reg） */
            int opt = (i >> 13) & 7, s = (i >> 12) & 1, rm = (i >> 16) & 0x1F;
            uint64_t off;
            if (opt == 2) off = (uint64_t)(uint32_t)RZR(rm);     /* UXTW */
            else if (opt == 3) off = RZR(rm);                    /* LSL(64) */
            else if (opt == 6) off = (uint64_t)(int64_t)(int32_t)RZR(rm);  /* SXTW */
            else if (opt == 7) off = (uint64_t)(int64_t)RZR(rm);  /* SXTX */
            else { fprintf(stderr, "[emu] UNSUPPORTED fp-ld/st opt=%d i=%#x pc=%#llx\n", opt, i, (unsigned long long)E.pc); return 1; }
            if (s) off <<= sz;
            uint64_t a = RSP(rn(i)) + off;
            if (opc == 0) mem_st(a, E.v[rd][0], nbytes);
            else if (opc == 1) { uint64_t x = mem_ld(a, nbytes); E.v[rd][0] = x; }
            else { fprintf(stderr, "[emu] UNSUPPORTED fp-ld/st opc=%d pc=%#llx\n", opc, (unsigned long long)E.pc); return 1; }
            E.pc += 4; return 0;
        }
        if (i & 0x01000000) {                             /* bit24=1：STR/LDR imm12（bit21=0 且 bit24=1） */
            uint64_t a = RSP(rn(i)) + ((((i >> 10) & 0xFFF) << sz));
            if (opc == 0) mem_st(a, E.v[rd][0], nbytes);  /* STR B/H/S/D */
            else if (opc == 1) { uint64_t x = mem_ld(a, nbytes); E.v[rd][0] = x; }
            else { fprintf(stderr, "[emu] UNSUPPORTED fp-ld/st opc=%d pc=%#llx\n", opc, (unsigned long long)E.pc); return 1; }
            E.pc += 4; return 0;
        }
        {                                             /* STUR/LDUR imm9（unscaled）+ pre/post-index（bit26=1 且 bit21=0 且 bit24=0）；
                                                         v19.20：补 opt 判定——pre(bits11-10=3)/post(=1) 需写回 Rn，
                                                         此前全按 unscaled 处理导致 str d15,[x1,#0x38]! 不写回 x1，
                                                         后续 str w,[x1,#8] 误写首项 code_max=0xffffffff（[0-9]/./a+ 全行匹配根因） */
            int64_t imm9 = sext((i >> 12) & 0x1FF, 9);
            int opt = (i >> 10) & 3;
            uint64_t base = RSP(rn(i)), a;
            if (opt == 0) a = base + (uint64_t)imm9;                       /* unscaled */
            else if (opt == 1) { a = base; W(rn(i), base + (uint64_t)imm9); }   /* post-index：addr=base，Rn+=imm9 */
            else if (opt == 3) { a = base + (uint64_t)imm9; W(rn(i), a); }      /* pre-index：addr=base+imm9，Rn=addr */
            else a = base + (uint64_t)imm9;                                /* opt=2 保留位，保守 unscaled */
            if (opc == 0) mem_st(a, E.v[rd][0], nbytes);
            else if (opc == 1) { uint64_t x = mem_ld(a, nbytes); E.v[rd][0] = x; }
            else { fprintf(stderr, "[emu] UNSUPPORTED fp-ld/st opc=%d pc=%#llx\n", opc, (unsigned long long)E.pc); return 1; }
            E.pc += 4; return 0;
        }
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
        if (m == 0x3C800000 && (i & 0x200000)) {         /* STR q（register offset，bit21=1） */
            uint64_t r = RZR((i >> 16) & 0x1F);
            int opt = (i >> 13) & 7, ss = (i >> 12) & 1;
            if (opt == 3 && ss) r <<= 1;                 /* LSL #1 */
            else if (opt == 7) r = (uint64_t)(int64_t)r; /* SXTX */
            else if (opt == 2) r = (uint32_t)r;          /* UXTW */
            else if (opt == 6) r = (uint64_t)(int32_t)r; /* SXTW */
            else if (opt == 0 && ss) r <<= 1;            /* LSL #1 */
            uint64_t a = RSP(rn(i)) + r;
            mem_st(a, E.v[rd(i)][0], 8); mem_st(a + 8, E.v[rd(i)][1], 8);
            E.pc += 4; return 0;
        }
        if (m == 0x3C800000 && !(i & 0x200000)) {         /* STUR q（imm9 带符号） */
            uint64_t a = RSP(rn(i)) + (uint64_t)sext((i >> 12) & 0x1FF, 9);
            mem_st(a, E.v[rd(i)][0], 8); mem_st(a + 8, E.v[rd(i)][1], 8);
            E.pc += 4; return 0;
        }
        if (m == 0x3CC00000 && (i & 0x200000)) {         /* LDR q（register offset） */
            uint64_t a = RSP(rn(i)) + RZR((i >> 16) & 0x1F);
            E.v[rd(i)][0] = mem_ld(a, 8); E.v[rd(i)][1] = mem_ld(a + 8, 8);
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

    /* ---- ADC/SBC/ADCS/SBCS（带进位加减，0x1A/0x3A/0x5A/0x7A W + 0x9A/0xBA/0xDA/0xFA X） ---- */
    if ((i & 0x1FE00000) == 0x1A000000 || (i & 0x1FE00000) == 0x3A000000 ||
        (i & 0x1FE00000) == 0x5A000000 || (i & 0x1FE00000) == 0x7A000000) {
        int sf = (i >> 31) & 1, op = (i >> 30) & 1, setf = (i >> 29) & 1;
        uint64_t a = RZR(rn(i)), b = RZR(rm(i));
        int c = (E.nzcv >> 29) & 1;
        uint64_t res, nc, nz;
        if (!op) { /* ADC */
            res = a + b + c;
            nc = (res < a) || (c && res == a) ? 1 : 0;
            uint64_t sg = 1ULL << (sf ? 63 : 31);
            nz = ((a & sg) == (b & sg)) && ((res & sg) != (a & sg)) ? 1 : 0;
        } else {   /* SBC：a - b - !C */
            uint64_t br = 1 - c;
            res = a - b - br;
            nc = (a >= b + br) ? 1 : 0;
            uint64_t sg = 1ULL << (sf ? 63 : 31);
            nz = ((a & sg) != (b & sg)) && ((res & sg) == (b & sg)) ? 1 : 0;
        }
        if (sf) W(rd(i), res); else W(rd(i), (uint32_t)res);
        if (setf) {
            uint32_t f = 0;
            if ((res >> (sf ? 63 : 31)) & 1) f |= 1u << 31;
            if ((sf ? res : (uint32_t)res) == 0) f |= 1u << 30;
            if (nc) f |= 1u << 29;
            if (nz) f |= 1u << 28;
            E.nzcv = f;
        }
        E.pc += 4; return 0;
    }

    /* ---- CSEL/CSINC/CSINV/CSNEG ---- (CSEL/CSINC=0x1A800000 系 op=00；CSINV/CSNEG=0x5A800000 系 op=10；op2: 00=base/01=inc/neg；SDIV/UDIV 的 op2=11 由 op 位排除) */
    if ((i & 0xFFE00000) == 0x1A800000 || (i & 0xFFE00000) == 0x5A800000 ||
        (i & 0xFFE00000) == 0x9A800000 || (i & 0xFFE00000) == 0xDA800000) {
        int op = (i >> 29) & 3;           /* 00=CSEL/CSINC  10=CSINV/CSNEG（v19.6：原误取 bits22:21 → 0x5A80A401 cneg 被当 CSINC，keystone 实证 bits30:29） */
        int op2 = (i >> 10) & 3;          /* 00=base 01=inc/neg */
        int sf = (i >> 31) & 1, cond = (i >> 12) & 0xF;
        int c = (i >> 12) & 0xF;          /* v19.2 修复：CSEL 条件码在 bit[15:12]（原 i&0xF 误取 Rd 低位） */
        uint64_t a = RZR(rn(i)), b = RZR(rm(i));
        int t = cond_true(c);
        uint64_t res;
        if (op == 0) {
            if (op2 == 1) res = t ? a : (b + 1);
            else res = t ? a : b;
        } else {
            /* CSINV/CSNEG 的 cond 字段按工具链约定 = 标准^1（keystone/capstone/unicorn 三一致；
               unicorn 完整序列实证 0xf248 cneg w1,w0,lt(0x5A80A401,cond=0xA) 取反当 N≠V；
               busybox strtod 正确性依赖此语义） */
            t = cond_true((cond ^ 1) & 0xF);
            if (op2 == 1) res = t ? (~b + 1) : a;   /* CSNEG：cond 真→~Xm+1、假→Xn */
            else res = t ? ~b : a;                  /* CSINV：cond 真→~Xm、假→Xn */
            if (!sf) res = (uint32_t)res;
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

    /* ---- FMOV S/D imm（printf 浮点格式化的 1.0/0.5/0.125 等） ---- */
    if ((i & 0xFFE0FC00) == 0x1E201000 || (i & 0xFFE0FC00) == 0x1E601000) {
        int imm8 = (i >> 13) & 0xFF;
        int a = (imm8 >> 7) & 1, ex = (~(imm8 >> 4) & 7), fr = imm8 & 0xF;
        /* v19.12: 查表替代 pow(2.0,-ex)——宿主 libm pow 调用在本机触发 SIGSEGV
           （原因未明），查表更快且确定 */
        static const double p2[8] = {1.0, 0.5, 0.25, 0.125, 0.0625, 0.03125, 0.015625, 0.0078125};
        double v = (a ? -1.0 : 1.0) * (1.0 + fr / 16.0) * p2[ex & 7];
        int type = ((i & 0xFFE0FC00) == 0x1E601000) ? 1 : 0;
        fp_st(rd(i), type, type ? v : (float)v);
        E.pc += 4; return 0;
    }

    /* ---- EXTR（strtod/floatscan 位提取） ---- */
    if ((i & 0xFFE00000) == 0x93C00000) {
        int imm = (i >> 10) & 0x3F; uint64_t v = RZR(rn(i)), w = RZR((i >> 16) & 0x1F);
        W(rd(i), imm == 0 ? v : ((v << (64 - imm)) | (w >> imm))); E.pc += 4; return 0;
    }
    if ((i & 0xFFE00000) == 0x13800000) {
        int imm = (i >> 10) & 0x1F; uint32_t v = (uint32_t)RZR(rn(i)), w = (uint32_t)RZR((i >> 16) & 0x1F);
        W(rd(i), (uint64_t)(imm == 0 ? v : ((v << (32 - imm)) | (w >> imm)))); E.pc += 4; return 0;
    }

    /* ---- INS/FMOV vN.d[1], xM（musl long double 构造） ---- */
    if ((i & 0xFFFFFC00) == 0x9EAF0000) { E.v[rd(i)][1] = RZR((i >> 5) & 0x1F); E.pc += 4; return 0; } /* FMOV vN.d[1], xM */
    if ((i & 0xFFFFFC00) == 0x9EAC0000) { E.v[rd(i)][0] = RZR((i >> 5) & 0x1F); E.pc += 4; return 0; } /* FMOV vN.d[0], xM */

    /* ---- REV16/REV32/REV（printf %.1f 的 strtod 小数解析需要） ---- */
    if ((i & 0xFFFFFC00) == 0x5AC00400) { uint32_t v = (uint32_t)RZR(rn(i)); W(rd(i), (uint64_t)(uint32_t)(((v & 0xFF00FF00u) >> 8) | ((v & 0x00FF00FFu) << 8))); E.pc += 4; return 0; } /* REV16 W */
    if ((i & 0xFFFFFC00) == 0xDAC00400) { uint64_t v = RZR(rn(i)); W(rd(i), ((v & 0xFF00FF00FF00FF00ULL) >> 8) | ((v & 0x00FF00FF00FF00FFULL) << 8)); E.pc += 4; return 0; } /* REV16 X */
    if ((i & 0xFFFFFC00) == 0x5AC00800) { uint32_t v = (uint32_t)RZR(rn(i)); W(rd(i), (uint64_t)(uint32_t)__builtin_bswap32(v)); E.pc += 4; return 0; } /* REV32 W */
    if ((i & 0xFFFFFC00) == 0xDAC00800) { uint64_t v = RZR(rn(i)); W(rd(i), __builtin_bswap64(v)); E.pc += 4; return 0; } /* REV32 X */
    if ((i & 0xFFFFFC00) == 0xDAC00C00) { uint64_t v = RZR(rn(i)); W(rd(i), __builtin_bswap64(v)); E.pc += 4; return 0; } /* REV X */

    /* ---- 标量浮点（v19.5：seq/printf %g 需要；host double 直算） ---- */
    if ((i & 0xFF20FC00) == 0x1E200800) {   /* FMUL s/d */
        int type = (i >> 22) & 1;
        fp_st(rd(i), type, fp_ld(rn(i), type) * fp_ld(rm(i), type));
        E.pc += 4; return 0;
    }
    if ((i & 0xFF20FC00) == 0x1E201800) {   /* FDIV s/d */
        int type = (i >> 22) & 1;
        fp_st(rd(i), type, fp_ld(rn(i), type) / fp_ld(rm(i), type));
        E.pc += 4; return 0;
    }
    if ((i & 0xFF20FC00) == 0x1E202800) {   /* FADD s/d */
        int type = (i >> 22) & 1;
        fp_st(rd(i), type, fp_ld(rn(i), type) + fp_ld(rm(i), type));
        E.pc += 4; return 0;
    }
    if ((i & 0xFF20FC00) == 0x1E203800) {   /* FSUB s/d */
        int type = (i >> 22) & 1;
        fp_st(rd(i), type, fp_ld(rn(i), type) - fp_ld(rm(i), type));
        E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x1E604000) { fp_st(rd(i), 1, fp_ld(rn(i), 1)); E.pc += 4; return 0; } /* FMOV d,d */
    if ((i & 0xFFFFFC00) == 0x1E204000) { fp_st(rd(i), 0, fp_ld(rn(i), 0)); E.pc += 4; return 0; } /* FMOV s,s */
    if ((i & 0xFFFFFC00) == 0x1E60C000) { fp_st(rd(i), 1, fabs(fp_ld(rn(i), 1))); E.pc += 4; return 0; } /* FABS d */
    if ((i & 0xFFFFFC00) == 0x1E20C000) { fp_st(rd(i), 0, fabsf((float)fp_ld(rn(i), 0))); E.pc += 4; return 0; } /* FABS s */
    if ((i & 0xFFFFFC00) == 0x1E614000) { fp_st(rd(i), 1, -fp_ld(rn(i), 1)); E.pc += 4; return 0; } /* FNEG d */
    if ((i & 0xFFFFFC00) == 0x1E214000) { fp_st(rd(i), 0, -fp_ld(rn(i), 0)); E.pc += 4; return 0; } /* FNEG s */
    if ((i & 0xFFFFFC00) == 0x1E61C000) { fp_st(rd(i), 1, sqrt(fp_ld(rn(i), 1))); E.pc += 4; return 0; } /* FSQRT d */
    if ((i & 0xFFFFFC00) == 0x1E21C000) { fp_st(rd(i), 0, sqrtf((float)fp_ld(rn(i), 0))); E.pc += 4; return 0; } /* FSQRT s */
    if ((i & 0xFFE0FC1F) == 0x1E602000 || (i & 0xFFE0FC1F) == 0x1E602010 ||
        (i & 0xFFE0FC1F) == 0x1E602008 || (i & 0xFFE0FC1F) == 0x1E602018) {
        /* FCMP/FCMPE d,d / d,#0.0（含 0x1E612000 系与 opc 变体） */
        double a = fp_ld(rn(i), 1);
        double b = (i & 0x08) ? 0.0 : fp_ld((i >> 16) & 0x1F, 1);   /* FCMP Rm 在 bit[20:16]（0xb22a4 fcmpe d0,d10 实证） */
        int un = isnan(a) || isnan(b);
        uint32_t f = 0;
        if (a < b) f |= 1u << 31;      /* N */
        if (a == b) f |= 1u << 30;     /* Z */
        if (a >= b) f |= 1u << 29;     /* C */
        if (un) f |= 1u << 28;         /* V */
        E.nzcv = f;
        E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x1E22C000) { fp_st(rd(i), 1, (double)fp_ld(rn(i), 0)); E.pc += 4; return 0; } /* FCVT d,s */
    if ((i & 0xFFFFFC00) == 0x1E624000) { fp_st(rd(i), 0, (float)fp_ld(rn(i), 1)); E.pc += 4; return 0; } /* FCVT s,d */
    /* ---- SCVTF/UCVTF fixed（#fbits）：w/x 源 → d，d = s / 2^fbits ---- */
    if ((i & 0xFFFF03C0) == 0x1E420000 || (i & 0xFFFF03C0) == 0x9E420000) {   /* SCVTF Dd, Wn/Xn, #fbits */
        int sf = (i >> 31) & 1, fbits = 64 - ((i >> 10) & 0x3F);
        int64_t s = sf ? (int64_t)RZR(rn(i)) : (int32_t)(uint32_t)RZR(rn(i));
        fp_st(rd(i), 1, ldexp((double)s, -fbits));
        E.pc += 4; return 0;
    }
    if ((i & 0xFFFF03C0) == 0x1E430000 || (i & 0xFFFF03C0) == 0x9E430000) {   /* UCVTF Dd, Wn/Xn, #fbits */
        int sf = (i >> 31) & 1, fbits = 64 - ((i >> 10) & 0x3F);
        uint64_t s = sf ? RZR(rn(i)) : (uint32_t)RZR(rn(i));
        fp_st(rd(i), 1, ldexp((double)s, -fbits));
        E.pc += 4; return 0;
    }
    /* ---- FCVTZS/FCVTZU fixed（#fbits）：d/s 源 → 整数（向零截断） ---- */
    if ((i & 0xFFFF03C0) == 0x9E7C0000 || (i & 0xFFFF03C0) == 0x1E7C0000 ||
        (i & 0xFFFF03C0) == 0x9E7D0000 || (i & 0xFFFF03C0) == 0x1E7D0000) {   /* x/w,d 源 */
        int sf = (i >> 31) & 1, fbits = 64 - ((i >> 10) & 0x3F);
        double scaled = fp_ld(rn(i), 1) * ldexp(1.0, fbits);
        if (i & 0x10000) { uint64_t u = (uint64_t)scaled; E.r[rd(i)] = sf ? u : (uint32_t)u; }
        else { int64_t s = (int64_t)scaled; E.r[rd(i)] = sf ? (uint64_t)s : (uint32_t)s; }
        E.pc += 4; return 0;
    }
    if ((i & 0xFFFF03C0) == 0x9E180000 || (i & 0xFFFF03C0) == 0x1E180000 ||
        (i & 0xFFFF03C0) == 0x9E190000 || (i & 0xFFFF03C0) == 0x1E190000) {   /* x/w,s 源 */
        int sf = (i >> 31) & 1, fbits = 64 - ((i >> 10) & 0x3F);
        double scaled = fp_ld(rn(i), 0) * ldexp(1.0, fbits);
        if (i & 0x10000) { uint64_t u = (uint64_t)scaled; E.r[rd(i)] = sf ? u : (uint32_t)u; }
        else { int64_t s = (int64_t)scaled; E.r[rd(i)] = sf ? (uint64_t)s : (uint32_t)s; }
        E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x9E780000 || (i & 0xFFFFFC00) == 0x1E780000) {   /* FCVTZS x/w,d */
        double a = fp_ld((i >> 5) & 0x1F, 1);
        int64_t r = (int64_t)a;

        if ((i >> 31) & 1) W(rd(i), (uint64_t)r); else W(rd(i), (uint64_t)(int32_t)r);
        E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x5EE1B800) {   /* FCVTZS Vd.2D, Vn.2D（sleep 0.1 浮点→整数） */
        double a1; memcpy(&a1, &E.v[(i >> 5) & 0x1F][1], 8);
        E.v[rd(i)][0] = (uint64_t)(int64_t)fp_ld((i >> 5) & 0x1F, 1);
        E.v[rd(i)][1] = (uint64_t)(int64_t)a1;
        E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x5E61B800) {   /* FCVTMS Vd.2D, Vn.2D（floor→int） */
        double a1; memcpy(&a1, &E.v[(i >> 5) & 0x1F][1], 8);
        E.v[rd(i)][0] = (uint64_t)(int64_t)floor(fp_ld((i >> 5) & 0x1F, 1));
        E.v[rd(i)][1] = (uint64_t)(int64_t)floor(a1);
        E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x7E61B800) {   /* FCVTMU Vd.2D, Vn.2D（ceil→uint） */
        double a1; memcpy(&a1, &E.v[(i >> 5) & 0x1F][1], 8);
        E.v[rd(i)][0] = (uint64_t)ceil(fp_ld((i >> 5) & 0x1F, 1));
        E.v[rd(i)][1] = (uint64_t)ceil(a1);
        E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x5E61D800) {   /* SCVTF Vd.2D, Vn.2D（int→double） */
        int rn = (i >> 5) & 0x1F;
        double d0 = (double)(int64_t)E.v[rn][0];
        double d1 = (double)(int64_t)E.v[rn][1];
        memcpy(&E.v[rd(i)][0], &d0, 8);
        memcpy(&E.v[rd(i)][1], &d1, 8);
        E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x7E61D800) {   /* UCVTF Vd.2D, Vn.2D（uint→double） */
        int rn = (i >> 5) & 0x1F;
        double d0 = (double)(uint64_t)E.v[rn][0];
        double d1 = (double)(uint64_t)E.v[rn][1];
        memcpy(&E.v[rd(i)][0], &d0, 8);
        memcpy(&E.v[rd(i)][1], &d1, 8);
        E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x7EE1B800) {   /* FCVTZU Vd.2D, Vn.2D */
        double a1; memcpy(&a1, &E.v[(i >> 5) & 0x1F][1], 8);
        E.v[rd(i)][0] = (uint64_t)fp_ld((i >> 5) & 0x1F, 1);
        E.v[rd(i)][1] = (uint64_t)a1;
        E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x9E790000 || (i & 0xFFFFFC00) == 0x1E790000) {   /* FCVTZU x/w,d */
        double a = fp_ld((i >> 5) & 0x1F, 1);
        uint64_t r = (uint64_t)a;
        if (!((i >> 31) & 1)) r = (uint32_t)r;
        W(rd(i), r); E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x9E620000 || (i & 0xFFFFFC00) == 0x1E620000) {   /* SCVTF d,x / s,w */
        int type = (i >> 22) & 1;
        int64_t v = ((i >> 31) & 1) ? (int64_t)RZR(rn(i)) : (int32_t)RZR(rn(i));
        fp_st(rd(i), type, (double)v); E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x9E630000 || (i & 0xFFFFFC00) == 0x1E630000) {   /* UCVTF d,x / s,w */
        int type = (i >> 22) & 1;
        uint64_t v = ((i >> 31) & 1) ? RZR(rn(i)) : (uint32_t)RZR(rn(i));
        fp_st(rd(i), type, (double)v); E.pc += 4; return 0;
    }
    if ((i & 0xFFFFFC00) == 0x1E260000) { union { float f; uint32_t u; } cv; cv.f = (float)fp_ld(rn(i), 0); W(rd(i), cv.u); E.pc += 4; return 0; } /* FMOV w,s：位复制（非数值转换！grep 正则 . 的 floatscan 依赖） */
    if ((i & 0xFFFFFC00) == 0x1E270000) { union { float f; uint32_t u; } cv; cv.u = (uint32_t)RZR(rn(i)); fp_st(rd(i), 0, cv.f); E.pc += 4; return 0; } /* FMOV s,w：位复制 */
    if ((i & 0xFFFFFC00) == 0x9E660000) { W(rd(i), E.v[rn(i)][0]); E.pc += 4; return 0; } /* FMOV x,d：位模式复制（0xf470 long double 构造依赖） */
    if ((i & 0xFFFFFC00) == 0x9E670000) { E.v[rd(i)][0] = RZR(rn(i)); E.v[rd(i)][1] = 0; E.pc += 4; return 0; } /* FMOV d,x：位模式复制（非数值转换！0xf880 窄化依赖） */
    if ((i & 0xFFFFFC00) == 0x9EAE0000) { E.r[i & 0x1F] = E.v[(i >> 5) & 0x1F][1]; E.pc += 4; return 0; } /* FMOV Xd, Vn.D[1]：高 64 位→GP（0xF62D0 等） */
    if ((i & 0xFFFFFC00) == 0x9E6E0000) { E.v[i & 0x1F][1] = RZR((i >> 5) & 0x1F); E.pc += 4; return 0; } /* FMOV Vd.D[1], Xn：GP→高 64 位（0xF6324 等） */
    if ((i & 0xFF000000) == 0x1F000000) {   /* FMADD/FMSUB/FNMADD/FNMSUB——ARM: Sd = Sa ± Sn*Sm；Sa=bits[14:10]、Sn=bits[20:16]、Sm=bits[9:5]（0xb229c fmadd d0,d8,d1,d9 依赖；rn/rm 宏反义不可用） */
        int type = (i >> 22) & 1;
        double a = fp_ld((i >> 10) & 0x1F, type), b = fp_ld((i >> 16) & 0x1F, type), c = fp_ld((i >> 5) & 0x1F, type);
        double r = ((i >> 15) & 1) ? a - b * c : a + b * c;
        fp_st(rd(i), type, r); E.pc += 4; return 0;
    }
    return unsupported(i);
}

int emu_run(uint64_t entry, uint64_t sp) {
    memset(&E, 0, sizeof(E));
    E.pc = entry;
    E.sp = sp;
    g_emu_active = 1;
    if (setjmp(g_emu_jmp) != 0) {
        fprintf(stderr, "[emu] mem fault @ pc=0x%llx (pc-off=0x%llx base=0x%llx) x0=0x%llx sp=0x%llx x1=0x%llx x2=0x%llx x19=0x%llx x20=0x%llx x21=0x%llx x23=0x%llx x24=0x%llx x30=0x%llx x6=0x%llx x16=0x%llx x17=0x%llx x22=0x%llx x25=0x%llx\n",
                (unsigned long long)E.pc, (unsigned long long)(E.pc - g_base), (unsigned long long)g_base,
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
    if (getenv("FGETC_TRACE")) g_fgetc_trace = 1;
    if (getenv("INS_TRACE")) g_iotrace = 1;

    while (!E.exited) {
        if (exec_one()) break;
        if (++steps > 3000000000ULL) {
            fprintf(stderr, "[emu] STEP LIMIT pc=0x%llx\n", (unsigned long long)E.pc);
            tr_dump();
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

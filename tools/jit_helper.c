// jit_helper.c — 自举 JIT 授权（照抄 TrollStore RootHelper/jit.m）
//
// 用法：jit_helper <pid>
//   PT_ATTACHEXC attach 目标进程 → 100ms → PT_DETACH（授权持续到进程结束）
// 独立进程（root persona）attach 主进程 = 外部调试附加（有效），
// 区别于 App 主进程自己 ptrace 自己（"进程不能同步调试自己"，无效 → SIGBUS）。
//
// 参考：https://github.com/opa334/TrollStore/blob/main/RootHelper/jit.m
//   int enableJIT(...) { pid = ...; ptrace(PT_ATTACHEXC, pid, 0, 0); usleep(100000);
//                        ptrace(PT_DETACH, pid, 0, 0); return 0; }

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <sys/types.h>
#include <stdint.h>

// iOS SDK 无 sys/ptrace.h——与 TrollStore RootHelper/jit.m 一致，手动声明
int ptrace(int request, pid_t pid, void *addr, int data);

#ifndef PT_DETACH
#define PT_DETACH 11
#endif
#ifndef PT_ATTACHEXC
#define PT_ATTACHEXC 14
#endif

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: jit_helper <pid>\n");
        return EINVAL;
    }
    pid_t pid = (pid_t)strtol(argv[1], NULL, 10);
    if (pid <= 0) {
        fprintf(stderr, "jit_helper: bad pid '%s'\n", argv[1]);
        return ESRCH;
    }

    int ret = ptrace(PT_ATTACHEXC, pid, 0, 0);
    if (ret == -1) {
        fprintf(stderr, "jit_helper: PT_ATTACHEXC failed errno=%d\n", errno);
        return errno;
    }

    usleep(100000);  // 100ms，与 TrollStore RootHelper 一致

    ret = ptrace(PT_DETACH, pid, 0, 0);
    if (ret == -1) {
        fprintf(stderr, "jit_helper: PT_DETACH failed errno=%d\n", errno);
        return errno;
    }
    return 0;  // 0 = 成功（等价 TrollStore 手动开 JIT 成功）
}

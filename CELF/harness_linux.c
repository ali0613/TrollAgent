/* Linux harness for CELF emu — 本地复现 busybox 行为（替代 iOS 环境） */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <stdint.h>

/* csops: iOS 专有。Linux 上直接返回 -1（无签名环境），不影响解释器路径 */
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize) {
    (void)pid; (void)ops; (void)useraddr; (void)usersize;
    return -1;
}

int elf_runner_main(int argc, char **argv);

#ifdef LOCAL_HARNESS
int main(int argc, char **argv) {
    /* v19.12: 用 _exit 跳过 libc 清理——guest 0x580000 区 MAP_FIXED 可能覆盖宿主
       映射，正常 return 走 atexit/stdio 清理会访问被覆盖区 → 宿主 SIGSEGV */
    int r = elf_runner_main(argc, argv);
    _exit(r);
}
#endif

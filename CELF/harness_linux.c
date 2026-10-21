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

int main(int argc, char **argv) {
    return elf_runner_main(argc, argv);
}

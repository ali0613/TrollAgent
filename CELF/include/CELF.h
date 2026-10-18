#ifndef CELF_h
#define CELF_h
// 14c8: elf-runner 编译进主二进制（Swift @main 走 --elf-runner 模式调用）。
// 绕开 TrollStore 不替换 bin/ + iOS 拒绝 spawn Documents 独立二进制两个死结：
// 主二进制覆盖安装即替换 + 自带 App 特权 entitlement（platform-application/no-sandbox）被信任。
int elf_runner_main(int argc, char **argv);
#endif

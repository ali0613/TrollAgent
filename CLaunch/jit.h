#ifndef CLaunch_jit_h
#define CLaunch_jit_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * 14d3: 请求 TrollStore 为本进程开启 JIT（apple-magnifier://enable-jit URL scheme）。
 * 返回 LSOpenCFURLRef 的 OSStatus（0 = 成功投递）。
 */
int troll_request_jit(const char *bundle_id);

#ifdef __cplusplus
}
#endif

#endif /* CLaunch_jit_h */

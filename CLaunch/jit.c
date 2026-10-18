#include "jit.h"

#include <stdio.h>
#include <string.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>

/*
 * 14d3: 请求 TrollStore 为本进程开启 JIT（apple-magnifier://enable-jit URL scheme）。
 * 放 C 层：LSOpenCFURLRef 是 C API，Swift 的 CoreServices overlay 不暴露（编译报
 * cannot find 'LSOpenCFURLRef' in scope）。
 *
 * bundle_id: 当前 App 的 bundle id（如 org.python.python）
 *
 * 返回 LSOpenCFURLRef 的 OSStatus（0 = 成功投递；非 0 = URL 未注册/TrollStore 未响应）。
 */
int troll_request_jit(const char *bundle_id) {
    char buf[512];
    snprintf(buf, sizeof(buf), "apple-magnifier://enable-jit?bundle-id=%s", bundle_id);
    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, buf, kCFStringEncodingUTF8);
    if (!s) return -1;
    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, s, NULL);
    CFRelease(s);
    if (!url) return -1;
    OSStatus st = LSOpenCFURLRef(url, NULL);
    CFRelease(url);
    return (int)st;
}

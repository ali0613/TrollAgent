#include "jit.h"

#include <stdio.h>
#include <string.h>
#include <dlfcn.h>

#include <CoreFoundation/CoreFoundation.h>

/*
 * 14d5: 请求 TrollStore 为本进程开启 JIT（apple-magnifier://enable-jit URL scheme）。
 * LSOpenCFURLRef 不在 iOS 公开 SDK 头文件（LaunchServices 在 iOS 为私有 API，
 * 14d4 编译实证 implicit-function-declaration）——改 dlsym 运行时解析，
 * 符号位于系统 LaunchServices，App 进程可直接调用。
 *
 * bundle_id: 当前 App 的 bundle id（如 org.python.python）
 *
 * 返回 0 = 成功投递；-1 = dlsym 未找到（TrollStore 未注册该 scheme）；其他 = LSOpenCFURLRef 错误码。
 */
int troll_request_jit(const char *bundle_id) {
    char buf[512];
    snprintf(buf, sizeof(buf), "apple-magnifier://enable-jit?bundle-id=%s", bundle_id);
    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, buf, kCFStringEncodingUTF8);
    if (!s) return -1;
    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, s, NULL);
    CFRelease(s);
    if (!url) return -1;

    typedef int (*OpenURLFn)(CFURLRef, void *);
    OpenURLFn fn = (OpenURLFn)dlsym(RTLD_DEFAULT, "LSOpenCFURLRef");
    int st = -1;
    if (fn) {
        st = fn(url, NULL);
    }
    CFRelease(url);
    return st;
}

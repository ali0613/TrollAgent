#include "jit.h"

#include <stdio.h>
#include <string.h>
#include <dlfcn.h>

#include <CoreFoundation/CoreFoundation.h>

/*
 * 14d6: 请求 TrollStore 为本进程开启 JIT（apple-magnifier://enable-jit URL scheme）。
 * LSOpenCFURLRef 不在 iOS 公开 SDK 头文件（14d4 实证），且 14d5 实证 RTLD_DEFAULT
 * dlsym 找不到——App 进程默认未加载 LaunchServices。改 dlopen 显式加载
 * /System/Library/Frameworks/LaunchServices.framework 再取符号（iOS 固定路径）。
 *
 * bundle_id: 当前 App 的 bundle id（如 org.python.python）
 *
 * 返回 0 = 成功投递；<0 = 失败阶段（-1 dlopen/-2 dlsym/-3 调用）。
 */
int troll_request_jit(const char *bundle_id) {
    char buf[512];
    snprintf(buf, sizeof(buf), "apple-magnifier://enable-jit?bundle-id=%s", bundle_id);
    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, buf, kCFStringEncodingUTF8);
    if (!s) return -3;
    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, s, NULL);
    CFRelease(s);
    if (!url) return -3;

    void *h = dlopen("/System/Library/Frameworks/LaunchServices.framework/LaunchServices",
                     RTLD_LAZY | RTLD_GLOBAL);
    if (!h) { CFRelease(url); return -1; }

    typedef int (*OpenURLFn)(CFURLRef, void *);
    OpenURLFn fn = (OpenURLFn)dlsym(h, "LSOpenCFURLRef");
    int st = -2;
    if (fn) {
        st = fn(url, NULL);
    }
    dlclose(h);
    CFRelease(url);
    return st;
}

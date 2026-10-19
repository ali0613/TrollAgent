#include "jit.h"

#include <stdio.h>
#include <string.h>

#include <objc/runtime.h>
#include <objc/message.h>
#include <CoreFoundation/CoreFoundation.h>

/*
 * 14db: 请求 TrollStore 为本进程开启 JIT（apple-magnifier://enable-jit URL scheme）。
 * 14d6/14d8 实证：iOS16 LaunchServices.framework 不在文件系统（全进 dyld shared cache，
 * dlopen 固定路径失败，LSOpen err=-1）。改 LSApplicationWorkspace 私有类：
 * objc_getClass 查类（随 UIKit 依赖链自动加载），无需 dlopen；openURL: 接受 NSURL
 * （CFURL toll-free bridge）。
 *
 * bundle_id: 当前 App 的 bundle id（如 org.python.python）
 *
 * 返回 0 = 成功投递；<0 = 失败阶段（-1 类不存在/-2 workspace 空/-3 URL 创建失败/-4 openURL 返回 NO）。
 */
int troll_request_jit(const char *bundle_id) {
    char buf[512];
    snprintf(buf, sizeof(buf), "apple-magnifier://enable-jit?bundle-id=%s", bundle_id);
    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, buf, kCFStringEncodingUTF8);
    if (!s) return -3;
    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, s, NULL);
    CFRelease(s);
    if (!url) return -3;

    Class cls = objc_getClass("LSApplicationWorkspace");
    if (!cls) { CFRelease(url); return -1; }
    id ws = ((id(*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("defaultWorkspace"));
    if (!ws) { CFRelease(url); return -2; }
    BOOL ok = ((BOOL(*)(id, SEL, id))objc_msgSend)(ws, sel_registerName("openURL:"), (id)url);
    CFRelease(url);
    return ok ? 0 : -4;
}

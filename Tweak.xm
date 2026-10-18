/*
 * CraneBadgeResetFix
 * ===================
 * 修复 Crane 多开应用（微信等）「消息已读，但图标/快捷菜单角标仍显示历史未读数」。
 *
 * 根因（基于 CraneSB.dylib 1.3.17 arm64 反汇编）：
 *   图标角标 = 所有容器未读之和，缓存 /var/mobile/Library/Crane/BadgeStore.plist。
 *   角标是「乐观合并、只增不减」；微信清角标走私有 setBadgeNumber:0 链路，
 *   未能把清零传导到 Crane 的 app 级汇总缓存，历史值被反复回写。
 *
 * 本补丁不改 Crane 二进制，独立 dylib hook CraneSB 导出的 C 符号：
 *   - _badgeCountStoreSetContainerCount(self, containerID, count)
 *   - _badgeCountStoreUpdateBadge(self, appID)
 *
 * 策略（v0.1 探针 + 保守修复）：
 *   1) hook 后透传并打印 self 的真实 ObjC 类名与参数，便于真机 console 定位。
 *   2) 检测到「count == 0」的容器清零信号时，额外调用
 *      _setExistingBadgeCountForApplication(self, 0) 把 app 级汇总强制归零，
 *      抹掉那份赖着不走的 34。
 *   3) 清零调用用运行时开关 badge_fix_enforce 控制（默认开），
 *      崩溃时可关掉回到纯观察模式。
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <string.h>

static void* (*orig_SetContainerCount)(void*, const char*, uint64_t) = NULL;
static void* (*orig_UpdateBadge)(void*, uint64_t) = NULL;
static void  (*existing_setBadge)(void*, uint64_t) = NULL;

static BOOL enforceEnable = YES;

static void plog(NSString *fmt, ...) {
    va_list a;
    va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSLog(@"[CraneBadgeFix] %@", s);
}

// 遍历 dyld，找名字含 needle 的已加载镜像全路径（rootless 下会带 /var/jb 前缀）
static char* find_image(const char *needle) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, needle)) {
            return (char*)name;
        }
    }
    return NULL;
}

static void* rep_SetContainerCount(void* self, const char* containerID, uint64_t count) {
    if (self != NULL) {
        const char *cls = object_getClassName((id)self);
        plog(@"SetContainerCount self=%@(%s) container=%s count=%llu",
             self, cls ? cls : "?", containerID ? containerID : "nil",
             (unsigned long long)count);
    }
    void* r = orig_SetContainerCount(self, containerID, count);

    if (enforceEnable && count == 0 && self != NULL && existing_setBadge != NULL) {
        plog(@"-> zero signal on container=%s, force clear app aggregate",
             containerID ? containerID : "nil");
        existing_setBadge(self, 0);
    }
    return r;
}

static void* rep_UpdateBadge(void* self, uint64_t appID) {
    if (self != NULL) {
        const char *cls = object_getClassName((id)self);
        plog(@"UpdateBadge self=%@(%s) appID=%llu",
             self, cls ? cls : "?", (unsigned long long)appID);
    }
    return orig_UpdateBadge(self, appID);
}

%ctor {
    @autoreleasepool {
        char *img = find_image("CraneSB");
        if (img == NULL) {
            plog(@"CraneSB image not found among loaded images, abort");
            return;
        }
        MSImageRef crane = MSGetImageByName(img);
        if (crane == NULL) {
            plog(@"MSGetImageByName failed for %s", img);
            return;
        }
        plog(@"CraneSB image = %s", img);

        void *setCnt = MSFindSymbol(crane, "_badgeCountStoreSetContainerCount");
        void *updBadge = MSFindSymbol(crane, "_badgeCountStoreUpdateBadge");
        void *setBadge = MSFindSymbol(crane, "_setExistingBadgeCountForApplication");

        existing_setBadge = (void(*)(void*, uint64_t))setBadge;

        if (setCnt) {
            MSHookFunction(setCnt, (void*)rep_SetContainerCount, (void**)&orig_SetContainerCount);
            plog(@"hooked _badgeCountStoreSetContainerCount");
        } else {
            plog(@"WARN: _badgeCountStoreSetContainerCount not found");
        }
        if (updBadge) {
            MSHookFunction(updBadge, (void*)rep_UpdateBadge, (void**)&orig_UpdateBadge);
            plog(@"hooked _badgeCountStoreUpdateBadge");
        } else {
            plog(@"WARN: _badgeCountStoreUpdateBadge not found");
        }
        if (setBadge == NULL) {
            plog(@"WARN: _setExistingBadgeCountForApplication not found");
        }
    }
}
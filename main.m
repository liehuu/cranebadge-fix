/*
 * CraneBadgeFix v0.3
 * ===================
 * 修复 Crane 1.3.17 多开应用（微信等）「消息已读后，快捷菜单（Haptic Touch）
 * 仍残留 per-container 未读数」。
 *
 * 根因（CraneSB.dylib 1.3.17 arm64e 分片反汇编确认）：
 *   - 图标角标 = _badgeCountStoreGetAppCount(appID, 1)：遍历容器求和。
 *   - 快捷菜单 = _badgeCountStoreGetContainerCount(appID, containerID, 1)：
 *     每个容器单独显示（_crane_replacementMenu @0xf798 处确认调用点）。
 *   - 微信清角标走 -setBadgeNumber:forBundleIdentifier:withCompletionHandler:，
 *     被 Crane 的 _privSetBadgeNumberHook(@0x7c5c) 拦截。
 *     当它拿不到 containerID 时（0x7cc0 cbz / 0x7d14 cbz x23）会走「直接透传」
 *     分支(0x7db0)：系统角标被置 0（图标角标因此消失），但 Crane 的
 *     per-container 缓存完全没被更新 → 快捷菜单继续显示历史值。
 *     这就是 v0.2 只 hook SetContainerCount 却修不掉快捷菜单的原因。
 *
 * 本补丁策略（不改 Crane 二进制，独立 dylib 运行时解析）：
 *   1) hook _privSetBadgeNumberHook：捕获「角标被设为 0」信号，标记该 app。
 *   2) hook _badgeCountStoreGetContainerCount：已标记 app 一律返回 0。
 *      该出口同时服务于快捷菜单读取与 GetAppCount 求和，故两条路径一起归零。
 *   3) 保留 hook _badgeCountStoreSetContainerCount 作为第二清零信号来源。
 *
 * 编译：与抖音插件同款直编方案（.github/workflows/build.yml），纯 arm64e。
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <string.h>

#pragma mark - substrate 运行时解析

typedef void (*MSHookFunction_t)(void *symbol, void *hook, void **old);
static MSHookFunction_t pMSHookFunction = NULL;

static void resolve_substrate(void) {
    void *h = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/ellekit.dylib", RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/substrate.dylib", RTLD_NOW);
    if (h) pMSHookFunction = (MSHookFunction_t)dlsym(h, "MSHookFunction");
    if (!pMSHookFunction) pMSHookFunction = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
}

#pragma mark - 定位 CraneSB 已加载镜像

static char *find_image(const char *needle) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, needle)) return (char *)name;
    }
    return NULL;
}

#pragma mark - CraneSB 导出函数签名（arm64e 反汇编确认：对象参数均被 objc_retain）

// 第一个参数是 appID（bundle id），不是 self
typedef unsigned long long (*getContainerCount_t)(id appID, id containerID, unsigned long long flag);
typedef void (*setContainerCount_t)(id appID, id containerID, unsigned long long count);
typedef void (*setExistingBadge_t)(id appID, unsigned long long count);
// - (void)setBadgeNumber:(NSNumber *)n forBundleIdentifier:(NSString *)bid
//      withCompletionHandler:(id)h 的 hook replacement
typedef void (*privSetBadge_t)(id self, SEL _cmd, id badgeNumberObj, id bundleID, id completion);

static getContainerCount_t orig_GetContainerCount = NULL;
static setContainerCount_t orig_SetContainerCount = NULL;
static privSetBadge_t      orig_PrivSetBadge      = NULL;
static setExistingBadge_t  real_SetExistingBadge  = NULL;

#pragma mark - 已清零 app 集合（角标被设为 0 的 bundle id）

static NSMutableSet *g_clearedApps = nil;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static BOOL is_string(id obj) {
    return obj && [obj isKindOfClass:[NSString class]];
}

static void mark_cleared(id appID, BOOL cleared) {
    if (!is_string(appID)) return;
    pthread_mutex_lock(&g_lock);
    if (cleared) {
        if (![g_clearedApps containsObject:appID]) {
            [g_clearedApps addObject:appID];
            NSLog(@"[CraneBadgeFix] mark cleared: %@", appID);
        }
    } else {
        if ([g_clearedApps containsObject:appID]) {
            [g_clearedApps removeObject:appID];
            NSLog(@"[CraneBadgeFix] unmark cleared: %@", appID);
        }
    }
    pthread_mutex_unlock(&g_lock);
}

static BOOL is_cleared(id appID) {
    if (!is_string(appID)) return NO;
    pthread_mutex_lock(&g_lock);
    BOOL r = [g_clearedApps containsObject:appID];
    pthread_mutex_unlock(&g_lock);
    return r;
}

#pragma mark - 替换函数

// 2) per-container 读取出口：快捷菜单 + GetAppCount 求和都走这里
static unsigned long long rep_GetContainerCount(id appID, id containerID, unsigned long long flag) {
    unsigned long long cnt = 0;
    if (orig_GetContainerCount) cnt = orig_GetContainerCount(appID, containerID, flag);
    if (cnt > 0 && is_cleared(appID)) {
        NSLog(@"[CraneBadgeFix] suppress stale container badge %llu (app=%@ container=%@)",
              cnt, appID, containerID);
        return 0;
    }
    return cnt;
}

// 3) 保留 v0.2 的第二清零信号：容器计数被设为 0 时也标记
static void rep_SetContainerCount(id appID, id containerID, unsigned long long count) {
    if (orig_SetContainerCount) orig_SetContainerCount(appID, containerID, count);
    if (count == 0) {
        mark_cleared(appID, YES);
        if (real_SetExistingBadge) real_SetExistingBadge(appID, 0);
    }
}

// 1) 捕获「app 把角标设为 0」的信号（微信清角标入口）
static void rep_PrivSetBadge(id self, SEL _cmd, id badgeNumberObj, id bundleID, id completion) {
    // 先透传，保证 Crane 自身逻辑不受影响
    if (orig_PrivSetBadge) orig_PrivSetBadge(self, _cmd, badgeNumberObj, bundleID, completion);

    // badgeNumberObj 是 NSNumber（可能是 tagged pointer），nil 时 respondsToSelector 返回 NO
    long long v = -1;
    if (badgeNumberObj && [badgeNumberObj respondsToSelector:@selector(longLongValue)]) {
        v = [badgeNumberObj longLongValue];
    }
    if (v == 0) {
        mark_cleared(bundleID, YES);
    } else if (v > 0) {
        mark_cleared(bundleID, NO);
    }
}

#pragma mark - 入口

__attribute__((constructor)) static void CBFInit(void) {
    @autoreleasepool {
        resolve_substrate();
        if (!pMSHookFunction) {
            NSLog(@"[CraneBadgeFix] substrate 不可用，退出");
            return;
        }

        char *crane = find_image("CraneSB");
        if (!crane) {
            NSLog(@"[CraneBadgeFix] 未找到 CraneSB 镜像，退出");
            return;
        }

        void *h = dlopen(crane, RTLD_NOW);
        if (!h) {
            NSLog(@"[CraneBadgeFix] dlopen CraneSB 失败: %s", crane);
            return;
        }

        g_clearedApps = [[NSMutableSet alloc] init];

        void *getCnt = dlsym(h, "_badgeCountStoreGetContainerCount");
        void *setCnt = dlsym(h, "_badgeCountStoreSetContainerCount");
        void *privB  = dlsym(h, "_privSetBadgeNumberHook");
        real_SetExistingBadge = (setExistingBadge_t)dlsym(h, "_setExistingBadgeCountForApplication");

        if (getCnt) pMSHookFunction(getCnt, (void *)rep_GetContainerCount, (void **)&orig_GetContainerCount);
        if (setCnt) pMSHookFunction(setCnt, (void *)rep_SetContainerCount, (void **)&orig_SetContainerCount);
        if (privB)  pMSHookFunction(privB,  (void *)rep_PrivSetBadge,      (void **)&orig_PrivSetBadge);

        NSLog(@"[CraneBadgeFix] v0.3 初始化完成 getContainer=%d setContainer=%d privSetBadge=%d setExisting=%d (CraneSB=%s)",
              getCnt != NULL, setCnt != NULL, privB != NULL, real_SetExistingBadge != NULL, crane);
    }
}

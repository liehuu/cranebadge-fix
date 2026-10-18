/*
 * CraneBadgeFix v0.4
 * ===================
 * 修复 Crane 1.3.17 多开应用（微信等）「消息已读后，快捷菜单（Haptic Touch）
 * 仍残留 per-container 未读数」，并且让清零结果持久化（重启 SpringBoard 后
 * 角标不再复活）。
 *
 * ── 根因（CraneSB.dylib 1.3.17 反汇编确认）────────────────────────────
 *   - 图标角标   = _badgeCountStoreGetAppCount(appID, 1)：遍历容器求和。
 *   - 快捷菜单   = _badgeCountStoreGetContainerCount(appID, cid, 1)：
 *                  每个容器单独显示（调用点 _crane_replacementMenu @0xf798）。
 *   - 微信清角标走 -setBadgeNumber:forBundleIdentifier:withCompletionHandler:，
 *     被 Crane 的 _privSetBadgeNumberHook(@0x7c5c) 拦截。它拿不到 containerID
 *     时（0x7cc0 cbz / 0x7d14 cbz x23）会走「直接透传」分支(0x7db0)：
 *     系统角标被置 0（图标角标因此消失），但 Crane 的 per-container 缓存
 *     与 BadgeStore.plist 完全没动 → 快捷菜单继续显示历史值。
 *
 * ── v0.3 为什么完全无效（本次实测定位）──────────────────────────────
 *   CraneSB 的 LC_DYLD_EXPORTS_TRIE 里 **不包含** badge 相关符号：
 *     _privSetBadgeNumberHook / _badgeCountStoreGetContainerCount /
 *     _badgeCountStoreSetContainerCount / _setExistingBadgeCountForApplication
 *   它们虽在 symtab（N_SECT|N_EXT）但未导出 → dlsym() 全部返回 NULL，
 *   三个 hook 一个都没挂上。所以 v0.3 装上等于没装。
 *
 * ── v0.4 定位方案 ──────────────────────────────────────────────────
 *   CraneSB 两个分片的 __TEXT vmaddr 均为 0，symtab 的 n_value 即 vmaddr，
 *   故 运行时地址 = slide + vmaddr。
 *     slide   ← _dyld_get_image_vmaddr_slide(index)
 *     分片    ← mh->cpusubtype == 0x80000002 → arm64e；== 0 → arm64
 *   先按地址下钩，dlsym 仅作为 fallback。
 *
 * ── 持久化 ─────────────────────────────────────────────────────────
 *   v0.3 的 postinst 删了 BadgeStore.plist，但没重启 SpringBoard，Crane 在
 *   退出时把内存里的旧计数又写回 plist → 用户看到「重启后角标又回来」。
 *   v0.4 改为：启动后 12 秒「清零模式」把 Crane 从 plist 恢复的存量计数
 *   压成 0（经 orig 回写，plist 随之变干净），同时启动时直接递归清零
 *   BadgeStore.plist 里的所有数字。postinst 不再 killall SpringBoard，
 *   装完补丁需用户手动重启一次 SpringBoard（或关机重启）才生效。
 *
 * 编译：.github/workflows/build.yml 直编，纯 arm64e。
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <pthread.h>
#import <string.h>

#pragma mark - substrate

typedef void (*MSHookFunction_t)(void *symbol, void *hook, void **old);
static MSHookFunction_t pMSHookFunction = NULL;

static void resolve_substrate(void) {
    void *h = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/ellekit.dylib", RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/substrate.dylib", RTLD_NOW);
    if (h) pMSHookFunction = (MSHookFunction_t)dlsym(h, "MSHookFunction");
    if (!pMSHookFunction) pMSHookFunction = (MSHookFunction_t)dlsym(h ? h : RTLD_DEFAULT, "MSHookFunction");
    if (!pMSHookFunction) pMSHookFunction = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
}

#pragma mark - 定位 CraneSB：slide + cpusubtype

static uintptr_t g_slide = 0;
static BOOL      g_arm64e = NO;
static const char *g_cranePath = NULL;

typedef struct {
    uintptr_t getCnt;       // _badgeCountStoreGetContainerCount
    uintptr_t setCnt;       // _badgeCountStoreSetContainerCount
    uintptr_t getApp;       // _badgeCountStoreGetAppCount
    uintptr_t setExisting;  // _setExistingBadgeCountForApplication
    uintptr_t privSet;      // _privSetBadgeNumberHook
} crane_offs_t;

// 1.3.17 symtab 实测偏移
static const crane_offs_t kOffArm64e = { 0x6acc, 0x6f54, 0x6c4c, 0x69f8, 0x7c5c };
static const crane_offs_t kOffArm64  = { 0x6734, 0x6b34, 0x689c, 0x6590, 0x7774 };

static const crane_offs_t *cur_offs(void) { return g_arm64e ? &kOffArm64e : &kOffArm64; }

static BOOL locate_crane(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "CraneSB")) continue;
        g_slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (mh && mh->magic == MH_MAGIC_64) {
            uint32_t sub = mh->cpusubtype & 0x00FFFFFFu;
            g_arm64e = (sub == 2);           // CPU_SUBTYPE_ARM64E
        }
        g_cranePath = name;
        return YES;
    }
    return NO;
}

static void *crane_fn(uintptr_t off) {
    if (!g_slide) return NULL;
    return (void *)(g_slide + off);
}

// 先按 slide+vmaddr 下钩；若 orig 仍为 NULL（地址不对）再退回 dlsym
static BOOL hook_one(void **orig, uintptr_t off, const char *sym, void *hook) {
    void *byAddr = crane_fn(off);
    if (byAddr) {
        memset(orig, 0, sizeof(void *));
        pMSHookFunction(byAddr, hook, orig);
        if (*orig) {
            NSLog(@"[CraneBadgeFix] hooked %-34s @%p (slide+0x%lx)", sym, byAddr, (unsigned long)off);
            return YES;
        }
        NSLog(@"[CraneBadgeFix] slide+0x%lx 对 %s 下钩失败（地址无效），退回 dlsym", (unsigned long)off, sym);
    }
    void *viaSym = dlsym(RTLD_DEFAULT, sym);
    if (viaSym) {
        memset(orig, 0, sizeof(void *));
        pMSHookFunction(viaSym, hook, orig);
        if (*orig) {
            NSLog(@"[CraneBadgeFix] hooked %-34s @%p (dlsym)", sym, viaSym);
            return YES;
        }
    }
    NSLog(@"[CraneBadgeFix] *** 目标函数 %s 无法定位，补丁不完整 ***", sym);
    return NO;
}

#pragma mark - CraneSB 函数签名（arm64e 反汇编确认）

typedef unsigned long long (*getContainerCount_t)(id appID, id containerID, unsigned long long flag);
typedef void              (*setContainerCount_t)(id appID, id containerID, unsigned long long count);
typedef unsigned long long (*getAppCount_t)(id appID, unsigned long long flag);
typedef void              (*setExistingBadge_t)(id appID, unsigned long long count);
typedef void              (*privSetBadge_t)(id self, SEL _cmd, id badgeNumberObj, id bundleID, id completion);

static getContainerCount_t orig_GetContainerCount = NULL;
static setContainerCount_t orig_SetContainerCount = NULL;
static getAppCount_t       orig_GetAppCount       = NULL;
static privSetBadge_t      orig_PrivSetBadge      = NULL;
static setExistingBadge_t  real_SetExistingBadge  = NULL;

#pragma mark - 状态

static NSMutableSet       *g_clearedApps = nil;   // 角标已确认清零的 bundle id
static NSMutableDictionary *g_containers = nil;   // appID -> NSMutableSet(containerID)
static pthread_mutex_t      g_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile BOOL        g_zeroMode = NO;      // 启动清零模式
static BOOL                 g_inited = NO;

static BOOL is_string(id o) { return o && [o isKindOfClass:[NSString class]]; }

static void mark_cleared(id appID, BOOL cleared) {
    if (!is_string(appID)) return;
    pthread_mutex_lock(&g_lock);
    if (cleared) {
        if (![g_clearedApps containsObject:appID]) {
            [g_clearedApps addObject:appID];
            NSLog(@"[CraneBadgeFix] 已清零标记: %@", appID);
        }
    } else {
        if ([g_clearedApps containsObject:appID]) {
            [g_clearedApps removeObject:appID];
            NSLog(@"[CraneBadgeFix] 撤销清零标记: %@", appID);
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

static void remember_container(id appID, id containerID) {
    if (!is_string(appID) || !is_string(containerID)) return;
    pthread_mutex_lock(&g_lock);
    NSMutableSet *s = g_containers[appID];
    if (!s) { s = [NSMutableSet set]; g_containers[appID] = s; }
    [s addObject:containerID];
    pthread_mutex_unlock(&g_lock);
}

static void purge_containers(id appID) {
    if (!is_string(appID) || !orig_SetContainerCount) return;
    pthread_mutex_lock(&g_lock);
    NSArray *cids = [g_containers[appID] allObjects];
    pthread_mutex_unlock(&g_lock);
    for (id cid in cids) orig_SetContainerCount(appID, cid, 0);
    if (cids.count)
        NSLog(@"[CraneBadgeFix] 清空 %@ 的 %lu 个容器计数", appID, (unsigned long)cids.count);
}

#pragma mark - BadgeStore.plist 存量清零

static id scrub_value(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return @0;
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSDictionary *src = (NSDictionary *)v;
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithCapacity:src.count];
        for (id k in src) m[k] = scrub_value(src[k]);
        return m;
    }
    if ([v isKindOfClass:[NSArray class]]) {
        NSArray *src = (NSArray *)v;
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:src.count];
        for (id e in src) [a addObject:scrub_value(e)];
        return a;
    }
    return v;
}

static void scrub_plist(void) {
    static const char *paths[] = {
        "/var/jb/var/mobile/Library/Crane/BadgeStore.plist",
        "/var/mobile/Library/Crane/BadgeStore.plist"
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        NSString *p = [NSString stringWithUTF8String:paths[i]];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (!d) continue;
        NSDictionary *clean = scrub_value(d);
        if ([clean writeToFile:p atomically:YES]) {
            NSLog(@"[CraneBadgeFix] 已清零 BadgeStore.plist: %@", p);
        } else {
            NSLog(@"[CraneBadgeFix] 写回 BadgeStore.plist 失败: %@", p);
        }
    }
}

#pragma mark - 启动清零模式

#define ZERO_MODE_SECONDS 12

static void schedule_zero_mode(void) {
    g_zeroMode = YES;
    scrub_plist();
    NSLog(@"[CraneBadgeFix] 进入启动清零模式（%d 秒），把 Crane 恢复的历史角标压成 0", ZERO_MODE_SECONDS);

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    // 每 2 秒重刷一次，防止 Crane 在恢复过程中分批写回
    for (int i = 1; i <= ZERO_MODE_SECONDS / 2; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)), q, ^{
            if (g_zeroMode) scrub_plist();
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ZERO_MODE_SECONDS * NSEC_PER_SEC)), q, ^{
        g_zeroMode = NO;
        NSLog(@"[CraneBadgeFix] 启动清零模式结束，恢复正常计数显示");
    });
}

#pragma mark - 替换函数

// per-container 读取出口：快捷菜单走这里，GetAppCount 求和也走这里
static unsigned long long rep_GetContainerCount(id appID, id containerID, unsigned long long flag) {
    unsigned long long cnt = orig_GetContainerCount ? orig_GetContainerCount(appID, containerID, flag) : 0;
    remember_container(appID, containerID);
    if (cnt > 0 && (g_zeroMode || is_cleared(appID))) {
        NSLog(@"[CraneBadgeFix] 抑制容器角标 %llu (app=%@ container=%@ zero=%d)",
              cnt, appID, containerID, g_zeroMode);
        return 0;
    }
    return cnt;
}

// app 级读取出口（图标角标求和）
static unsigned long long rep_GetAppCount(id appID, unsigned long long flag) {
    unsigned long long cnt = orig_GetAppCount ? orig_GetAppCount(appID, flag) : 0;
    if (cnt > 0 && (g_zeroMode || is_cleared(appID))) {
        NSLog(@"[CraneBadgeFix] 抑制 app 角标 %llu (app=%@ zero=%d)", cnt, appID, g_zeroMode);
        return 0;
    }
    return cnt;
}

// 写入出口：清零模式下把非零计数压成 0，并经 orig 回写（plist 随之干净）
static void rep_SetContainerCount(id appID, id containerID, unsigned long long count) {
    remember_container(appID, containerID);

    if (g_zeroMode && count > 0) {
        NSLog(@"[CraneBadgeFix] 清零模式压零 container=%@ count=%llu", containerID, count);
        count = 0;
        if (orig_SetContainerCount) orig_SetContainerCount(appID, containerID, 0);
        mark_cleared(appID, YES);
        return;
    }

    if (count > 0) {
        mark_cleared(appID, NO);
    } else if (count == 0) {
        mark_cleared(appID, YES);
    }

    if (orig_SetContainerCount) orig_SetContainerCount(appID, containerID, count);

    if (count == 0 && real_SetExistingBadge) real_SetExistingBadge(appID, 0);
}

static void rep_SetExistingBadge(id appID, unsigned long long count) {
    if (g_zeroMode && count > 0) count = 0;
    else if (count > 0) mark_cleared(appID, NO);
    if (real_SetExistingBadge) real_SetExistingBadge(appID, count);
}

// 微信清角标入口：捕获「角标被设为 0」的信号
static void rep_PrivSetBadge(id self, SEL _cmd, id badgeNumberObj, id bundleID, id completion) {
    long long v = -1;
    if (badgeNumberObj && [badgeNumberObj respondsToSelector:@selector(longLongValue)]) {
        v = [badgeNumberObj longLongValue];
    }

    if (v == 0) {
        // 真正删除已知容器条目（回写 plist，持久化），再打标记兜底未记录到的容器
        purge_containers(bundleID);
        mark_cleared(bundleID, YES);
        NSLog(@"[CraneBadgeFix] 捕获 setBadgeNumber:0 app=%@，已清零全部容器", bundleID);
    } else if (v > 0) {
        mark_cleared(bundleID, NO);
    }

    if (orig_PrivSetBadge) orig_PrivSetBadge(self, _cmd, badgeNumberObj, bundleID, completion);
}

#pragma mark - 入口

static void install_hooks(void) {
    const crane_offs_t *o = cur_offs();

    hook_one((void **)&orig_GetContainerCount, o->getCnt,      "_badgeCountStoreGetContainerCount",      (void *)rep_GetContainerCount);
    hook_one((void **)&orig_SetContainerCount, o->setCnt,      "_badgeCountStoreSetContainerCount",      (void *)rep_SetContainerCount);
    hook_one((void **)&orig_GetAppCount,       o->getApp,      "_badgeCountStoreGetAppCount",            (void *)rep_GetAppCount);
    hook_one((void **)&orig_PrivSetBadge,      o->privSet,     "_privSetBadgeNumberHook",               (void *)rep_PrivSetBadge);

    // 这个不在 hook 列表里，只作为「清零后写回 app 级」的辅助出口
    real_SetExistingBadge = (setExistingBadge_t)crane_fn(o->setExisting);
    if (!real_SetExistingBadge) real_SetExistingBadge = (setExistingBadge_t)dlsym(RTLD_DEFAULT, "_setExistingBadgeCountForApplication");
    NSLog(@"[CraneBadgeFix] setExistingBadge 出口 @%p", real_SetExistingBadge);

    NSLog(@"[CraneBadgeFix] v0.4 hook 安装完成（CraneSB=%s slide=%p arch=%s）",
          g_cranePath ? g_cranePath : "?", (void *)g_slide, g_arm64e ? "arm64e" : "arm64");
}

__attribute__((constructor)) static void CBFInit(void) {
    @autoreleasepool {
        resolve_substrate();
        if (!pMSHookFunction) {
            NSLog(@"[CraneBadgeFix] substrate 不可用，退出");
            return;
        }

        g_clearedApps = [[NSMutableSet alloc] init];
        g_containers  = [[NSMutableDictionary alloc] init];

        // CraneSB 与本 dylib 同为 SpringBoard 注入，加载顺序不保证，做重试
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        const double delays[] = { 0.0, 0.5, 1.5, 3.0, 6.0 };
        size_t nDelays = sizeof(delays) / sizeof(delays[0]);
        // 注意：block 内不能直接引用数组类型变量（clang: cannot refer to
        // declaration with an array type inside block），故先把标量取出来再捕获。
        for (size_t i = 0; i < nDelays; i++) {
            const double d = delays[i];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), q, ^{
                if (g_inited) return;
                if (!locate_crane()) {
                    NSLog(@"[CraneBadgeFix] 尚未找到 CraneSB，%.1fs 后重试", d + 1.0);
                    return;
                }
                g_inited = YES;
                install_hooks();
                schedule_zero_mode();
            });
        }
    }
}

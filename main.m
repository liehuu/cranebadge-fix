/*
 * CraneBadgeFix v0.5
 * ===================
 * 修复 Crane 1.3.17 多开应用（微信等）「消息已读后，图标角标已消失、
 * 但快捷菜单（Haptic Touch）仍残留 per-container 未读数」。
 *
 * ── 根因（CraneSB.dylib 1.3.17 arm64e 反汇编确认）──────────────────
 *   - 图标角标 = _badgeCountStoreGetAppCount(appID, 1)：遍历容器求和。
 *   - 快捷菜单 = _badgeCountStoreGetContainerCount(appID, cid, 1)：
 *                每容器单独显示。
 *   扫描确认 GetContainerCount 共 **5 处** bl 调用点：
 *     0x6dbc _badgeCountStoreGetAppCount  (图标角标求和内部)
 *     0xcb20 / 0xcb34 _initNotificationSupport (Crane 启动时迁移/同步计数)
 *     0xfb88 _crane_replacementMenu        (快捷菜单)
 *     0x129e0 _initApplicationShortcutLateHooks_12Down (iOS 12+ 快捷菜单路径)
 *   微信清角标走 -setBadgeNumber:forBundleIdentifier:withCompletionHandler:，
 *   被 _privSetBadgeNumberHook(@0x7c5c) 拦截：
 *     x2=badgeNumber, x3=bundleID, x4=completion
 *     0x7cc0 cbz w0  → 0x7db0 「直接透传」：系统角标置 0（图标角标消失），
 *                      但 Crane per-container 缓存与 BadgeStore.plist 完全没动
 *                      → 快捷菜单继续显示历史值。这就是 v0.2/v0.3 修不掉的真因。
 *
 * ── v0.3 失效根因 ──────────────────────────────────────────────────
 *   CraneSB 的 LC_DYLD_EXPORTS_TRIE 不含 badge 相关符号（在 symtab 但未导出），
 *   dlsym 全返回 NULL，hook 从未挂上。
 * ── v0.4 改用 slide+vmaddr 直接对地址下钩（本次实测：图标角标已清零，
 *    说明 hook 生效；但快捷菜单仍显示 → 说明还有 ObjC 层的读取出口未覆盖）。
 * ── v0.5 三管齐下 ──────────────────────────────────────────────────
 *   A. slide+vmaddr 对地址下钩（C 函数层，覆盖上述 5 处调用点）
 *   B. ObjC runtime 动态 hook：定位 Crane 挂在系统类上的
 *      -badgeValueForBundleID: / -setBadgeValue:forBundleID:
 *      （这两个是快捷菜单角标的直接数据源，且**可通过 objc_getClass +
 *      class_getInstanceMethod 精确定位**，无需解析 chained fixups）
 *   C. 调用 Crane 自带的官方清零 API
 *      -crane_resetBadgeOfContainerWithIdentifier:ofApplicationWithIdentifier:
 *      真正删除 BadgeStore 条目
 *   D. **日志落盘**到 /var/jb/var/mobile/Library/Crane/CraneBadgeFix.log
 *      （也可在 /var/mobile/... ），手机端用「文稿/文本编辑器」或
 *      SSH `cat` 即可查看，postinst 会把路径 NSLog 出来。
 *
 * 编译：.github/workflows/build.yml 直编，纯 arm64e。
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <pthread.h>
#import <stdarg.h>
#import <string.h>

#pragma mark - 日志（同时输出到系统日志 + 文件）

static NSString *g_logPath = nil;
static dispatch_queue_t g_logQueue = nil;

static void CBFLogInit(void) {
    NSArray *cands = @[
        @"/var/jb/var/mobile/Library/Crane/CraneBadgeFix.log",
        @"/var/mobile/Library/Crane/CraneBadgeFix.log",
        @"/tmp/CraneBadgeFix.log",
    ];
    for (NSString *p in cands) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm isWritableFileAtPath:dir]) { g_logPath = p; break; }
    }
    if (!g_logPath) g_logPath = @"/tmp/CraneBadgeFix.log";
    g_logQueue = dispatch_queue_create("com.82flex.cranebadgefix.log", DISPATCH_QUEUE_SERIAL);
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    NSLog(@"[CraneBadgeFix] 日志文件: %@", g_logPath);
}

static void CBFLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[CraneBadgeFix] %@", msg);
    if (!g_logPath || !g_logQueue) return;
    dispatch_async(g_logQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createFileAtPath:g_logPath contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        if (!fh) return;
        [fh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    });
}

#pragma mark - substrate

typedef void (*MSHookFunction_t)(void *symbol, void *hook, void **old);
static MSHookFunction_t pMSHookFunction = NULL;

static void resolve_substrate(void) {
    void *h = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/ellekit.dylib", RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/substrate.dylib", RTLD_NOW);
    if (h) pMSHookFunction = (MSHookFunction_t)dlsym(h, "MSHookFunction");
    if (!pMSHookFunction) pMSHookFunction = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!pMSHookFunction) CBFLog(@"!! substrate/MSHookFunction 不可用，补丁无法工作");
}

#pragma mark - 定位 CraneSB

static uintptr_t   g_slide = 0;
static BOOL        g_arm64e = NO;
static const char *g_cranePath = NULL;

typedef struct {
    uintptr_t getCnt, setCnt, getApp, setExisting, privSet;
} crane_offs_t;

// 1.3.17 symtab 实测偏移（arm64e / arm64 两分片）
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
            g_arm64e = ((mh->cpusubtype & 0x00FFFFFFu) == 2);  // CPU_SUBTYPE_ARM64E
        }
        g_cranePath = name;
        CBFLog(@"找到 CraneSB: %s  slide=%p  arch=%s", name, (void *)g_slide,
               g_arm64e ? "arm64e" : "arm64");
        return YES;
    }
    return NO;
}

static void *crane_fn(uintptr_t off) {
    if (!g_slide) return NULL;
    return (void *)(g_slide + off);
}

#pragma mark - 状态

typedef unsigned long long (*getContainerCount_t)(id appID, id containerID, unsigned long long flag);
typedef void              (*setContainerCount_t)(id appID, id containerID, unsigned long long count);
typedef unsigned long long (*getAppCount_t)(id appID, unsigned long long flag);
typedef void              (*privSetBadge_t)(id self, SEL _cmd, id badgeNumberObj, id bundleID, id completion);

static getContainerCount_t orig_GetContainerCount = NULL;
static setContainerCount_t orig_SetContainerCount = NULL;
static getAppCount_t       orig_GetAppCount       = NULL;
static privSetBadge_t      orig_PrivSetBadge      = NULL;

static NSMutableSet       *g_clearedApps = nil;
static NSMutableDictionary *g_containers = nil;
static pthread_mutex_t      g_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile BOOL        g_zeroMode = NO;
static BOOL                 g_inited = NO;

static BOOL is_string(id o) { return o && [o isKindOfClass:[NSString class]]; }

static void mark_cleared(id appID, BOOL cleared) {
    if (!is_string(appID)) return;
    pthread_mutex_lock(&g_lock);
    if (cleared) {
        if (![g_clearedApps containsObject:appID]) {
            [g_clearedApps addObject:appID];
            CBFLog(@"已清零标记: %@", appID);
        }
    } else {
        if ([g_clearedApps containsObject:appID]) {
            [g_clearedApps removeObject:appID];
            CBFLog(@"撤销清零标记: %@", appID);
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

#pragma mark - Crane 官方清零 API（ObjC runtime 动态定位）

// - (void)crane_resetBadgeOfContainerWithIdentifier:(NSString*)cid
//                     ofApplicationWithIdentifier:(NSString*)aid
// Crane 挂在系统通知相关类上的方法。用 runtime 扫描找到 owner 并缓存。
static NSString *g_resetOwnerName = nil;
static SEL  g_sel_reset = NULL;
static IMP  g_imp_reset = NULL;

static void discover_reset_api(void) {
    if (g_imp_reset) return;
    g_sel_reset = sel_registerName("crane_resetBadgeOfContainerWithIdentifier:ofApplicationWithIdentifier:");
    if (!g_sel_reset) return;

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        if (!c) continue;
        // 限定为 CraneSB 镜像里的类，避免误伤系统类
        const char *imgName = class_getImageName(c);
        if (!imgName || !strstr(imgName, "CraneSB")) continue;
        Method m = class_getInstanceMethod(c, g_sel_reset);
        if (m) {
            g_imp_reset = method_getImplementation(m);
            g_resetOwnerName = NSStringFromClass(c);
            CBFLog(@"找到 Crane 官方清零 API: -[%@ crane_resetBadgeOfContainerWithIdentifier:ofApplicationWithIdentifier:] IMP=%p",
                   g_resetOwnerName, (void *)g_imp_reset);
            break;
        }
    }
    free(classes);
    if (!g_imp_reset) {
        CBFLog(@"未在 CraneSB 镜像的类中找到 crane_resetBadge... API（将只用 C 函数路径）");
    }
}

typedef void (*resetBadge_t)(id self, SEL _cmd, id containerID, id appID);

static void purge_containers(id appID) {
    if (!is_string(appID)) return;
    pthread_mutex_lock(&g_lock);
    NSArray *cids = [g_containers[appID] allObjects];
    pthread_mutex_unlock(&g_lock);
    if (!cids.count) return;

    // 优先用 Crane 官方 API
    if (!g_imp_reset) discover_reset_api();
    if (g_imp_reset && g_resetOwnerName) {
        Class owner = NSClassFromString(g_resetOwnerName);
        for (id cid in cids) {
            ((resetBadge_t)g_imp_reset)(owner, g_sel_reset, cid, appID);
        }
        CBFLog(@"已调用 Crane 官方 reset API 清空 %@ 的 %lu 个容器",
               appID, (unsigned long)cids.count);
    }
    // 同时用 C 函数回写 0，保证 BadgeStore 干净
    if (orig_SetContainerCount) {
        for (id cid in cids) orig_SetContainerCount(appID, cid, 0);
    }
    CBFLog(@"purge 完成 app=%@ 容器数=%lu", appID, (unsigned long)cids.count);
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
        if ([clean writeToFile:p atomically:YES])
            CBFLog(@"已递归清零 BadgeStore.plist: %@", p);
    }
}

#pragma mark - 启动清零模式

#define ZERO_MODE_SECONDS 12

static void schedule_zero_mode(void) {
    g_zeroMode = YES;
    scrub_plist();
    CBFLog(@"进入启动清零模式 %d 秒", ZERO_MODE_SECONDS);

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    for (int i = 1; i <= ZERO_MODE_SECONDS / 2; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)), q, ^{
            if (g_zeroMode) scrub_plist();
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ZERO_MODE_SECONDS * NSEC_PER_SEC)), q, ^{
        g_zeroMode = NO;
        CBFLog(@"启动清零模式结束，恢复正常计数");
    });
}

#pragma mark - C 函数替换

static unsigned long long rep_GetContainerCount(id appID, id containerID, unsigned long long flag) {
    unsigned long long cnt = orig_GetContainerCount ? orig_GetContainerCount(appID, containerID, flag) : 0;
    remember_container(appID, containerID);
    if (cnt > 0 && (g_zeroMode || is_cleared(appID))) {
        CBFLog(@"抑制容器角标 %llu app=%@ cid=%@ zero=%d", cnt, appID, containerID, g_zeroMode);
        return 0;
    }
    return cnt;
}

static unsigned long long rep_GetAppCount(id appID, unsigned long long flag) {
    unsigned long long cnt = orig_GetAppCount ? orig_GetAppCount(appID, flag) : 0;
    if (cnt > 0 && (g_zeroMode || is_cleared(appID))) {
        CBFLog(@"抑制 app 角标 %llu app=%@ zero=%d", cnt, appID, g_zeroMode);
        return 0;
    }
    return cnt;
}

static void rep_SetContainerCount(id appID, id containerID, unsigned long long count) {
    remember_container(appID, containerID);
    if (g_zeroMode && count > 0) {
        CBFLog(@"清零模式压零 cid=%@ count=%llu", containerID, count);
        if (orig_SetContainerCount) orig_SetContainerCount(appID, containerID, 0);
        mark_cleared(appID, YES);
        return;
    }
    if (count > 0) mark_cleared(appID, NO);
    else if (count == 0) mark_cleared(appID, YES);
    if (orig_SetContainerCount) orig_SetContainerCount(appID, containerID, count);
}

static void rep_PrivSetBadge(id self, SEL _cmd, id badgeNumberObj, id bundleID, id completion) {
    long long v = -1;
    if (badgeNumberObj && [badgeNumberObj respondsToSelector:@selector(longLongValue)])
        v = [badgeNumberObj longLongValue];

    CBFLog(@"_privSetBadgeNumberHook 被调用 badgeNumber=%lld app=%@", v, bundleID);

    if (v == 0) {
        purge_containers(bundleID);
        mark_cleared(bundleID, YES);
    } else if (v > 0) {
        mark_cleared(bundleID, NO);
    }
    if (orig_PrivSetBadge) orig_PrivSetBadge(self, _cmd, badgeNumberObj, bundleID, completion);
}

#pragma mark - ObjC runtime 动态 hook（v0.5 新增，覆盖快捷菜单的 ObjC 层出口）

// - (id)badgeValueForBundleID:   —— 快捷菜单角标的直接数据源
static id (*orig_badgeValueForBundleID)(id, SEL, id) = NULL;
static void (*orig_setBadgeValueForBundleID)(id, SEL, id, id) = NULL;

static id rep_badgeValueForBundleID(id self, SEL _cmd, id bundleID) {
    id v = orig_badgeValueForBundleID ? orig_badgeValueForBundleID(self, _cmd, bundleID) : nil;
    long long n = 0;
    if (v && [v respondsToSelector:@selector(longLongValue)]) n = [v longLongValue];
    CBFLog(@"[badgeValueForBundleID:] app=%@ value=%lld", bundleID, n);
    if (n > 0 && (g_zeroMode || is_cleared(bundleID))) {
        CBFLog(@"  -> 抑制返回（已清零 app）");
        return @0;
    }
    return v;
}

static void rep_setBadgeValueForBundleID(id self, SEL _cmd, id value, id bundleID) {
    long long n = 0;
    if (value && [value respondsToSelector:@selector(longLongValue)]) n = [value longLongValue];
    CBFLog(@"[setBadgeValue:forBundleID:] app=%@ value=%lld", bundleID, n);
    if (g_zeroMode && n > 0) {
        CBFLog(@"  -> 清零模式压成 0");
        value = @0;
    }
    if (orig_setBadgeValueForBundleID) orig_setBadgeValueForBundleID(self, _cmd, value, bundleID);
}

// 扫描 CraneSB 镜像内所有类，找到实现指定 selector 的 owner 并下钩。
// 注意：ARC 下不能把全局 NSString* 的地址作为 __autoreleasing 出参写回
//   （error: passing address of non-local object to __autoreleasing parameter
//    for write-back），所以 owner 只记日志，不往外部回写。
static void hook_objc_selector(const char *selName, const char *label,
                               void *replacement, void **origOut) {
    SEL sel = sel_registerName(selName);
    if (!sel) return;
    MSHookFunction_t hooker = pMSHookFunction;
    if (!hooker) return;
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        if (!c) continue;
        const char *img = class_getImageName(c);
        if (!img || !strstr(img, "CraneSB")) continue;
        Method m = class_getInstanceMethod(c, sel);
        if (!m) continue;
        IMP imp = method_getImplementation(m);
        if (!imp) continue;
        memset(origOut, 0, sizeof(void *));
        hooker((void *)imp, replacement, origOut);
        if (*origOut) {
            CBFLog(@"已 hook %s -> -[%@ %s] IMP=%p", label, NSStringFromClass(c), selName, (void *)imp);
            free(classes);
            return;
        }
    }
    free(classes);
    CBFLog(@"!! 未找到实现 %s 的 CraneSB 类（%s）", selName, label);
}

static void install_objc_hooks(void) {
    discover_reset_api();
    hook_objc_selector("badgeValueForBundleID:", "badgeValueForBundleID",
                       (void *)rep_badgeValueForBundleID,
                       (void **)&orig_badgeValueForBundleID);
    hook_objc_selector("setBadgeValue:forBundleID:", "setBadgeValue:forBundleID:",
                       (void *)rep_setBadgeValueForBundleID,
                       (void **)&orig_setBadgeValueForBundleID);
}

#pragma mark - 安装 C 函数 hook

static void hook_addr(void **orig, uintptr_t off, const char *sym, void *hook) {
    void *byAddr = crane_fn(off);
    memset(orig, 0, sizeof(void *));
    if (byAddr) {
        pMSHookFunction(byAddr, hook, orig);
        if (*orig) { CBFLog(@"已 hook(C) %-34s @%p (slide+0x%lx)", sym, byAddr, (unsigned long)off); return; }
    }
    void *viaSym = dlsym(RTLD_DEFAULT, sym);
    if (viaSym) {
        memset(orig, 0, sizeof(void *));
        pMSHookFunction(viaSym, hook, orig);
        if (*orig) { CBFLog(@"已 hook(C) %-34s @%p (dlsym)", sym, viaSym); return; }
    }
    CBFLog(@"*** 目标函数 %s 定位失败 ***", sym);
}

static void install_hooks(void) {
    const crane_offs_t *o = cur_offs();
    hook_addr((void **)&orig_GetContainerCount, o->getCnt,  "_badgeCountStoreGetContainerCount", (void *)rep_GetContainerCount);
    hook_addr((void **)&orig_SetContainerCount, o->setCnt,  "_badgeCountStoreSetContainerCount", (void *)rep_SetContainerCount);
    hook_addr((void **)&orig_GetAppCount,       o->getApp,  "_badgeCountStoreGetAppCount",       (void *)rep_GetAppCount);
    hook_addr((void **)&orig_PrivSetBadge,      o->privSet, "_privSetBadgeNumberHook",          (void *)rep_PrivSetBadge);

    install_objc_hooks();

    CBFLog(@"v0.5 初始化完成。日志路径 %@", g_logPath);
}

__attribute__((constructor)) static void CBFInit(void) {
    @autoreleasepool {
        CBFLogInit();
        CBFLog(@"==== CraneBadgeFix v0.5 加载 ====");
        resolve_substrate();
        if (!pMSHookFunction) { CBFLog(@"substrate 不可用，退出"); return; }

        g_clearedApps = [[NSMutableSet alloc] init];
        g_containers  = [[NSMutableDictionary alloc] init];

        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        const double delays[] = { 0.0, 0.5, 1.5, 3.0, 6.0 };
        size_t nDelays = sizeof(delays) / sizeof(delays[0]);
        for (size_t i = 0; i < nDelays; i++) {
            const double d = delays[i];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), q, ^{
                if (g_inited) return;
                if (!locate_crane()) {
                    CBFLog(@"尚未找到 CraneSB，%.1fs 后重试", d + 1.0);
                    return;
                }
                g_inited = YES;
                install_hooks();
                schedule_zero_mode();
            });
        }
    }
}

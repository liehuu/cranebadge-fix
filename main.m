/*
 * CraneBadgeFix v0.7
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
#import <ctype.h>
#import <string.h>

#pragma mark - 日志（同时输出到系统日志 + 文件）

static NSString *g_logPath = nil;
static dispatch_queue_t g_logQueue = nil;
static NSDateFormatter *g_logFmt = nil;

// BadgeStore.plist 的真实路径（CraneSB __cstring 里写死的就是
// "/var/mobile/Library/Crane/BadgeStore.plist"，**没有 /var/jb 前缀**）。
// RootHide 下 /var/jb/var/mobile/... 虽也常可写，但必须两个都覆盖，
// 否则会出现「补丁写了 A 路径，Crane 读 B 路径」的假清零。
static NSString *badge_store_paths(void) {
    static NSArray *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = @[
            @"/var/mobile/Library/Crane/BadgeStore.plist",
            @"/var/jb/var/mobile/Library/Crane/BadgeStore.plist",
        ];
    });
    return paths;
}

static void CBFLogInit(void) {
    NSArray *cands = @[
        @"/var/mobile/Library/Crane/CraneBadgeFix.log",
        @"/var/jb/var/mobile/Library/Crane/CraneBadgeFix.log",
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

    g_logFmt = [[NSDateFormatter alloc] init];
    // 本地时区 + 毫秒，避免 [NSDate date] 的 description 只给 UTC
    //（用户会看到 13:47 而手机是 21:47，误以为日志过期）
    [g_logFmt setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    [g_logFmt setTimeZone:[NSTimeZone localTimeZone]];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:g_logPath]) {
        [fm createFileAtPath:g_logPath contents:nil attributes:nil];
    }
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
        // ⚠️ 关键：createFileAtPath:contents: 在文件已存在时会**清空文件**！
        //    v0.5 每次写日志都调用它，导致日志只剩最后一行（用户实测确认）。
        //    必须先判断存在，只在不存在时创建，然后 seek 到末尾追加。
        if (![fm fileExistsAtPath:g_logPath]) {
            [fm createFileAtPath:g_logPath contents:nil attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        if (!fh) return;
        [fh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                          [g_logFmt stringFromDate:[NSDate date]], msg];
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
//
// ⚠️ 定位要点（v0.6 实测日志证实的坑）：
//   Crane 是用 **category** 把这些 crane_* 方法挂到**系统私有类**上的，
//   而 `class_getImageName()` 返回的是**方法所在的镜像**（SpringBoard /
//   CoreUI / SBUserNotifications…），**不是 CraneSB**。
//   所以 v0.5/v0.6 里 `if (!strstr(imgName, "CraneSB")) continue;`
//   会把真正的 owner 全部过滤掉 → 日志一直是「未找到 crane_resetBadge... API」。
//   正确做法：selector 名本身已是 Crane 独有的（crane_ 前缀 / badgeValueForBundleID:），
//   可以安全地在**全量类**里匹配，不必再按镜像过滤。
static NSString *g_resetOwnerName = nil;
static SEL  g_sel_reset = NULL;
static IMP  g_imp_reset = NULL;
static BOOL g_resetSearchDone = NO;

static void discover_reset_api(void) {
    if (g_imp_reset || g_resetSearchDone) return;
    g_sel_reset = sel_registerName("crane_resetBadgeOfContainerWithIdentifier:ofApplicationWithIdentifier:");
    if (!g_sel_reset) { g_resetSearchDone = YES; return; }

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) { g_resetSearchDone = YES; return; }
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) { g_resetSearchDone = YES; return; }
    count = objc_getClassList(classes, count);

    // 优先命中 crane_ 前缀的 owner；记录命中的镜像名便于排查
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        if (!c) continue;
        Method m = class_getInstanceMethod(c, g_sel_reset);
        if (!m) continue;
        g_imp_reset = method_getImplementation(m);
        g_resetOwnerName = NSStringFromClass(c);
        const char *img = class_getImageName(c);
        CBFLog(@"找到 Crane 官方清零 API: -[%@ crane_resetBadgeOfContainerWithIdentifier:ofApplicationWithIdentifier:] IMP=%p (owner 镜像: %s)",
               g_resetOwnerName, (void *)g_imp_reset, img ? img : "?");
        break;
    }
    free(classes);
    g_resetSearchDone = YES;
    if (!g_imp_reset) {
        CBFLog(@"未在任何类中找到 crane_resetBadge... API（将只用 C 函数路径）");
    }
}

typedef void (*resetBadge_t)(id self, SEL _cmd, id containerID, id appID);

// 清掉**指定**的单个容器（精确到 cid），不牵连该 app 的其他容器。
// v0.6 实测教训：purge_containers(appID) 会清掉 g_containers[appID] 下
// **所有**容器，而 g_containers 里已经混入了「启动后新消息」的容器，
// 会把用户新收到的未读一并清掉。
static void purge_one(id appID, id cid) {
    if (!is_string(appID) || !is_string(cid)) return;
    if (!g_imp_reset) discover_reset_api();
    if (g_imp_reset && g_resetOwnerName) {
        Class owner = NSClassFromString(g_resetOwnerName);
        if (owner) ((resetBadge_t)g_imp_reset)(owner, g_sel_reset, cid, appID);
    }
    if (orig_SetContainerCount) orig_SetContainerCount(appID, cid, 0);
}

static void purge_containers(id appID) {
    if (!is_string(appID)) return;
    pthread_mutex_lock(&g_lock);
    NSArray *cids = [g_containers[appID] allObjects];
    pthread_mutex_unlock(&g_lock);
    if (!cids.count) return;

    for (id cid in cids) purge_one(appID, cid);

    if (g_imp_reset) {
        CBFLog(@"已用 Crane 官方 reset API 清空 %@ 的 %lu 个容器",
               appID, (unsigned long)cids.count);
    }
    CBFLog(@"purge 完成 app=%@ 容器数=%lu%s", appID, (unsigned long)cids.count,
           g_imp_reset ? @"（含官方 API）" : @"（仅 C 函数回写，官方 API 未找到）");
}

#pragma mark - BadgeStore.plist 存量清零

// 递归清零：把字典/数组里所有 NSNumber 压成 0
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

// plist 读取 + 诊断（v0.6 实测：harvest_from_plist 一行都没输出，
// 说明 dictionaryWithContentsOfFile: 返回了 nil，必须先查清为何读不到）
static NSDictionary *load_badge_store(NSString *p) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL exists = [fm fileExistsAtPath:p];
    unsigned long long sz = exists ? [[fm attributesOfItemAtPath:p error:nil] fileSize] : 0;
    NSData *raw = exists ? [NSData dataWithContentsOfFile:p] : nil;
    id obj = raw ? [NSPropertyListSerialization propertyListWithData:raw
                                                            options:NSPropertyListImmutable
                                                             format:NULL
                                                              error:NULL] : nil;
    CBFLog(@"BadgeStore 探测 %@ : exists=%d size=%llu bytes=%lu plist=%@",
           p, exists, sz, (unsigned long)raw.length,
           [obj isKindOfClass:[NSDictionary class]] ? @"dict" : (obj ? @"other" : @"nil"));
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static void scrub_plist(void) {
    for (NSString *p in badge_store_paths()) {
        NSDictionary *d = load_badge_store(p);
        if (!d) continue;
        NSDictionary *clean = scrub_value(d);
        if ([clean writeToFile:p atomically:YES])
            CBFLog(@"已递归清零 BadgeStore.plist: %@ (顶层 %lu 个 key)", p, (unsigned long)d.count);
    }
}

#pragma mark - 启动清零模式

// v0.4/v0.5 的清零模式只「守株待兔」等 SetContainerCount 被调用，
// 但 Crane 从 plist 恢复计数可能发生在 hook 装上之前，或走
// _existingBadgeCountForApplication 的读取路径 —— 于是漏掉，重启后红点复活。
//
// v0.6 改为**主动清零**：直接从 BadgeStore.plist 里解析出
// 所有 (appID -> containerID -> count)，用 Crane 官方 reset API 逐个清掉，
// 不再依赖「是否观察到调用」。
//
// plist 结构（由 _existingBadgeCountForApplication 反汇编推得）：
//   顶层 key = appID(bundle id)，value = { containerID: count, ... }
#define ZERO_MODE_SECONDS 30

// ── 结构自适应的 plist 遍历 ────────────────────────────────────────
// v0.6 实测教训：我预设的结构 {appID: {containerID: count}} 是**错的**。
// CraneSB __cstring 里紧贴 plist 路径的类型签名是：
//   'v32@?0@"NSString"8@"NSDictionary"16^B24'   （setObject:forKey:error:）
//   'v32@?0@"NSString"8@"NSNumber"16^B24'
// 两者都有，说明真实结构是**多层嵌套**，不是两级。
// 而且 __cstring 里有 '/var/jb'，plist 路径是**运行时拼接**的，
// 静态反推结构不可靠。
//
// 因此这里不做结构假设，而是递归下降 + 特征识别：
//   - 形如 com.xxx.yyy 且含点 → 当作 appID(bundle id)
//   - 形如 8-4-4-4-12 的 UUID    → 当作 containerID
//   - 遇到 NSNumber 且为非零     → 记 (最近appID, 最近containerID)
// 这样无论 Crane 以后怎么改嵌套层数都能适配。

static BOOL looks_like_bundle_id(NSString *s) {
    if (s.length < 4 || s.length > 120) return NO;
    if ([s rangeOfString:@"."].location == NSNotFound) return NO;
    // UUID 形如 2C76F901-11AD-... 含点吗？不含，但保险起见排除
    if ([s rangeOfString:@"-"].location != NSNotFound && [s rangeOfString:@"."].location == NSNotFound) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (!(isalnum(c) || c == '.' || c == '_' || c == '-')) return NO;
    }
    return YES;
}

static BOOL looks_like_container_id(NSString *s) {
    // 标准 UUID：8-4-4-4-12
    if (s.length != 36) return NO;
    NSArray *parts = [s componentsSeparatedByString:@"-"];
    if (parts.count != 5) return NO;
    NSUInteger expect[5] = {8, 4, 4, 4, 12};
    for (NSUInteger i = 0; i < 5; i++) {
        if ([parts[i] length] != expect[i]) return NO;
    }
    return YES;
}

static NSString *g_curAppID = nil;
static NSMutableDictionary *g_harvested = nil;   // "appID|cid" -> nil

static void walk_plist(id node, NSString *curApp, NSString *curCID) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)node;
        for (id k in d) {
            NSString *key = [k isKindOfClass:[NSString class]] ? k : nil;
            id v = d[k];
            NSString *nApp = curApp, *nCID = curCID;
            if (key && looks_like_bundle_id(key))       { nApp = key; nCID = nil; }
            else if (key && looks_like_container_id(key)) { nCID = key; }
            walk_plist(v, nApp, nCID);
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        // 数组：元素若是字典则继承当前上下文
        for (id e in (NSArray *)node) walk_plist(e, curApp, curCID);
    } else if ([node isKindOfClass:[NSNumber class]]) {
        long long n = [(NSNumber *)node longLongValue];
        if (n != 0 && curApp && curCID) {
            NSString *pair = [NSString stringWithFormat:@"%@|%@", curApp, curCID];
            if (![g_harvested[pair] boolValue]) {
                g_harvested[pair] = @YES;
                remember_container(curApp, curCID);
                CBFLog(@"从 plist 发现残留: app=%@ cid=%@ count=%lld", curApp, curCID, n);
            }
        }
    }
}

static void harvest_from_plist(void) {
    if (!g_harvested) g_harvested = [NSMutableDictionary dictionary];
    for (NSString *p in badge_store_paths()) {
        NSDictionary *d = load_badge_store(p);
        if (!d) continue;
        walk_plist(d, nil, nil);
    }
}

// 只 purge「启动前从 plist 扫出来的历史残留」，**不动**启动后新消息的容器。
// v0.6 实测教训：原来 purge_all_known() 直接遍历 g_containers，
// 而 g_containers 会被 rep_GetContainerCount 不断填入「新消息容器」，
// 导致用户开机后新到的未读被清掉（日志里 count=1/2/3 被依次吞掉）。
static void purge_harvested_only(void) {
    if (!g_harvested.count) return;
    for (NSString *pair in g_harvested) {
        NSArray *kv = [pair componentsSeparatedByString:@"|"];
        if (kv.count != 2) continue;
        purge_one(kv[0], kv[1]);   // 精确到单个容器，不碰该 app 的其他容器
    }
}

static void schedule_zero_mode(void) {
    g_zeroMode = YES;
    CBFLog(@"进入启动清零模式 %d 秒", ZERO_MODE_SECONDS);

    // 第 0 轮：先把 plist 里的历史残留登记进 g_harvested
    harvest_from_plist();
    CBFLog(@"启动清零：plist 历史残留 %lu 个 (app,cid) 组合", (unsigned long)g_harvested.count);

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    for (int i = 0; i < ZERO_MODE_SECONDS / 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 3.0 * NSEC_PER_SEC)), q, ^{
            if (!g_zeroMode) return;
            harvest_from_plist();      // 随时抓 Crane 又写回去的历史残留
            scrub_plist();             // 直接把 plist 数字压 0
            purge_harvested_only();    // 只清历史残留，不碰新消息
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ZERO_MODE_SECONDS * NSEC_PER_SEC)), q, ^{
        harvest_from_plist();
        scrub_plist();
        purge_harvested_only();
        g_zeroMode = NO;
        CBFLog(@"启动清零模式结束，已恢复正常计数");
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

    // ⚠️ v0.6 实测日志发现的设计缺陷：清零模式期间**真实新消息**也会被压零
    //   （日志：badgeNumber=1→2→3 被依次「清零模式压零」，用户新消息被吞）。
    //   清零模式的目的是清「启动时从 plist 恢复的历史残留」，
    //   而历史残留在启动那一刻就已经全部枚举完了（harvest_from_plist）。
    //   所以这里**不再**拦截写入，只保留标记更新 + 透传。
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

// 在全量类里找实现指定 selector 的 owner 并下钩。
// ⚠️ 不可按镜像过滤：Crane 用 category 把这些方法挂在**系统私有类**上，
//    class_getImageName() 返回的是系统镜像名而非 CraneSB
//    （v0.6 实测日志：一直打印「未找到实现 badgeValueForBundleID: 的 CraneSB 类」）。
//    selector 名本身已是 Crane 独有，全量匹配是安全的。
// 另外：hook 完必须调 class_addMethod 让 ObjC 侧 dispatch 也走新实现，
//    因为 CraneSB 内部是通过 objc_msgSend 调这些方法的。
// 注意：ARC 下不能把全局 NSString* 的地址作为 __autoreleasing 出参写回
//   （error: passing address of non-local object to __autoreleasing parameter
//    for write-back），所以 owner 只记日志，不往外部回写。
static Class g_badgeValueOwnerCls = NULL;
static Class g_setBadgeValueOwnerCls = NULL;

static void hook_objc_selector(const char *selName, const char *label,
                               void *replacement, void **origOut, Class *ownerOut) {
    SEL sel = sel_registerName(selName);
    if (!sel) return;
    MSHookFunction_t hooker = pMSHookFunction;
    if (!hooker) return;
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);
    int found = 0;
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        if (!c) continue;
        Method m = class_getInstanceMethod(c, sel);
        if (!m) continue;
        IMP imp = method_getImplementation(m);
        if (!imp) continue;
        memset(origOut, 0, sizeof(void *));
        hooker((void *)imp, replacement, origOut);
        if (*origOut) {
            const char *img = class_getImageName(c);
            // 关键：把类方法表里指向旧 IMP 的条目换成新 IMP，
            // 否则 objc_msgSend 仍会跳回原实现（MSHookFunction 只改代码）
            class_replaceMethod(c, sel, (IMP)replacement, method_getTypeEncoding(m));
            if (ownerOut) *ownerOut = c;
            CBFLog(@"已 hook %s -> -[%@ %s] IMP=%p (owner 镜像: %s)%@",
                   label, NSStringFromClass(c), selName, (void *)imp,
                   img ? img : "?", found ? " （同 owner 多类别，已一并处理）" : "");
            found++;
            if (found >= 4) break;   // 同一 selector 可能被多个类别实现，hook 最早的几个
        }
    }
    free(classes);
    if (!found) {
        CBFLog(@"!! 未找到实现 %s 的类（%s）", selName, label);
    }
}

static void install_objc_hooks(void) {
    discover_reset_api();
    hook_objc_selector("badgeValueForBundleID:", "badgeValueForBundleID",
                       (void *)rep_badgeValueForBundleID,
                       (void **)&orig_badgeValueForBundleID, &g_badgeValueOwnerCls);
    hook_objc_selector("setBadgeValue:forBundleID:", "setBadgeValue:forBundleID:",
                       (void *)rep_setBadgeValueForBundleID,
                       (void **)&orig_setBadgeValueForBundleID, &g_setBadgeValueOwnerCls);
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

    CBFLog(@"初始化完成。日志路径 %@", g_logPath);
}

__attribute__((constructor)) static void CBFInit(void) {
    @autoreleasepool {
        CBFLogInit();
        CBFLog(@"==== CraneBadgeFix v0.6 加载 ====");
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

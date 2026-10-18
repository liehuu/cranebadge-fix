/*
 * CraneBadgeFix v0.8.3（保守安全版）
 * ==============================
 * 修复 Crane 1.3.17 多开应用（微信等）「消息已读后，图标角标已消失、
 * 但快捷菜单（Haptic Touch）仍残留 per-container 未读数」。
 *
 * ── ⛔ v0.8 安全声明（最重要，请先读这段）─────────────────────────
 * v0.7 引入了 ObjC 运行时操作，导致**用户手机重启后死机、无法进入系统**
 * （只能关闭插件注入才能开机）。根因已定位且确定：
 *
 *   Class owner = NSClassFromString(g_resetOwnerName);
 *   ((resetBadge_t)g_imp_reset)(owner, g_sel_reset, cid, appID);
 *
 * `crane_resetBadgeOfContainerWithIdentifier:ofApplicationWithIdentifier:`
 * 是**系统私有类的【实例】方法**，v0.7 却把 `Class` 对象本身当成 `self` 传了进去。
 * 实例方法会去访问 self 的 ivar，而 Class 对象的内存布局与实例布局完全不同
 * → 越界访问 → EXC_BAD_ACCESS → SpringBoard 启动即崩溃 → 开不了机。
 *
 * （v0.6 没崩是因为它按镜像过滤、从未找到这个 API；v0.7 去掉过滤后开始找到，
 *   于是每次 purge 崩一次。）
 *
 * v0.8 决策：**删除全部未经验证的 ObjC 运行时操作**
 *   - 删除 crane_resetBadge... API 探测与调用
 *   - 删除 badgeValueForBundleID: / setBadgeValue:forBundleID: 的 class_replaceMethod
 * 只保留 v0.4/v0.5/v0.6 已在真机实机验证、且从未导致崩溃的 **C 函数层 hook**。
 * 另外给所有递归加了深度上限，防止 plist 异常时栈溢出。
 *
 * ⚠️ v0.8 是**保守版**：图标角标清零能力与 v0.6 相同（已验证有效），
 *    快捷菜单的深层修复暂缓——宁可少修，不可再崩。
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
 * ── v0.4 改用 slide+vmaddr 直接对地址下钩（实测：图标角标已清零，
 *    4 个 C hook 全部挂上，日志有据；但快捷菜单仍显示）。
 * ── v0.5 修日志落盘（v0.5 前每次写日志都清空文件，只剩最后一行）。
 * ── v0.6 修「启动清零吞掉真实新消息」+ 递归式 plist 自适应解析。
 * ── v0.7 引入 ObjC 运行时操作 → 死机。v0.8 全部回退。
 *
 * ── v0.8.1 实机修正（v0.8 全程失效，见下）─────────────────────────
 * v0.8 我把「镜像必须含 __TEXT 段」当成**过滤条件**，实机全部跳过：
 *   跳过无 __TEXT 的镜像: .../.jbroot-9AB6CCDA0F9265C2/.../CraneSB.dylib
 *   → 4 个 C hook 一个都没挂上，补丁完全无效。
 * 原因：RootHide 会改写 dylib 的 header / load commands，dyld 返回的
 *      mach_header 与标准预期不符，遍历 ncmds 找不到 __TEXT。
 *      但这个镜像**就是正确的 CraneSB**（v0.4~v0.6 实机连续验证成功）。
 * → 修正：__TEXT 检查**降级为纯诊断日志**，不再用于跳过镜像。
 *   过滤条件只保留「路径以 .dylib 结尾」（能可靠排除资源 bundle）。
 *
 * 同时修两个连带缺陷：
 *   1) 重试窗口过窄：v0.8 只排 5 次（0/0.5/1.5/3/6 秒）就永久放弃，
 *      实机恰好全落空 → 补丁不自愈。v0.8.1 改为两阶段：
 *      第一阶段密集（0~20 秒，8 次），第二阶段稀疏（30~300 秒，每 15 秒）。
 *   2) **新增并发风险并已修**：两阶段各自 `if (g_inited) return; ... g_inited = YES;`
 *      是非原子读-改-写，两个块同时命中会**双重进入 install_hooks()**
 *      → 对同一函数调两次 MSHookFunction → 原实现被换成我们的实现
 *      → 再换回来 → 无限递归 → 栈溢出崩溃。
 *      现用 claim_init() 在互斥锁内原子完成「检查+置位」。
 *
 * ── v0.8.2：修正 plist 读不到（持久化清零失效）─────────────────────
 * v0.8.1 实机日志：4 个 C hook **全部挂上**（修复生效），__TEXT=0 也证实
 *   v0.8 确实是误杀（RootHide 下 ncmds=33，比标准多 13 条，遍历找不到 __TEXT）。
 *   但暴露新问题：四个候选 BadgeStore.plist 路径 **全是 exists=0**，
 *   30 秒内读了 20 多次全 nil → harvest_from_plist 恒为空
 *   → g_harvested 恒为 0 → purge_harvested_only 恒为空操作
 *   → 清零只剩内存态的 mark_cleared，**一重启就失效**（用户的核心诉求）。
 *
 * 原因：RootHide 把 CraneSB 装在容器路径里（实机）：
 *   /private/var/containers/Bundle/Application/.jbroot-9AB6CCDA0F9265C2/usr/lib/TweakInject/CraneSB.dylib
 * 而 __cstring 含 '/var/jb'、路径运行时拼接，
 * 真实读写目标应为 <jbroot前缀>/var/mobile/Library/Crane/BadgeStore.plist。
 *
 * → v0.8.2：从 locate_crane() 拿到的**真实镜像路径动态推导** jbroot 前缀，
 *   生成候选路径；并新增一次性目录探测 dump_crane_dirs_once()，
 *   把候选目录的实际条目全打进日志。只列目录、纯只读、无副作用。
 *
 * ── v0.8.3：持久化清零已打通，本版专攻「快捷菜单」+ 补齐诊断盲区 ──────
 * v0.8.2 实机结论（用户确认）：
 *   - 图标角标清零：**正确**
 *   - 重启后清零：**有效**（持久化打通）
 *   - 快捷菜单：**仍然不行**（唯一未攻克项）
 *
 * 持久化打通的铁证 = BadgeStore.plist 大小变化（真实路径已确认）：
 *   /private/var/containers/Bundle/Application/.jbroot-9AB6CCDA0F9265C2/var/mobile/Library/Crane/BadgeStore.plist
 *   23:25:30 size=306 (count=5) → 23:25:36 size=350 (新消息写入)
 *   → 23:25:39 size=277  ← 数字被清成 0，plist 变小 = purge 真的写进去了
 *   23:27:14 size=350 (count=2) → 23:27:23 size=277 ← 再次清零成功
 *
 * ★ 关键诊断发现：v0.8.1/v0.8.2 实机日志里 **rep_SetContainerCount 一行都没有**，
 *   即微信清角标的「写」动作完全没走这个 C 函数。
 *   → 快捷菜单的残留在 v0.8.3 之前是**完全没被观测到**的，
 *     自然也无从判断该 hook 哪里。这才是「快捷菜单修不掉」的真正原因：
 *     不是 hook 错了，是**没看见数据从哪来**。
 *
 * v0.8.3 动作（全部只加诊断 + 修 bug，不新增任何高危操作）：
 *   1. rep_SetContainerCount 每次调用打日志 —— 补写路径盲区
 *   2. rep_GetContainerCount / rep_GetAppCount 有值时打日志 —— 确认读路径
 *   3. rep_PrivSetBadge 区分「清零信号 v=0」与「非清零信号 v>0」，
 *      并打出 purge 时的已知容器数 —— 验证清零信号是否真被捕获
 *   4. 修 dump_crane_dirs_once 的 bug：
 *      `[fm fileExistsAtPath:isDirectory:]` 返回的是「是否存在」而非 isDirectory 值，
 *      导致所有条目误报 (dir)。改用 attributesOfItemAtPath 的 NSFileType 判断。
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

// ⚠️ 前置声明：C 语言要求「先声明后使用」。
//   1) CBFLog：dump_crane_dirs_once()（下文）在其定义之前就要调用它。
//   2) g_cranePath：badge_store_paths() 要用它，而它的定义在「定位 CraneSB」段落。
//      缺少任一前置声明都会编译失败（implicit function declaration /
//      static declaration follows non-static declaration）。
static void CBFLog(NSString *fmt, ...);
static const char *g_cranePath = NULL;

// BadgeStore.plist 的候选路径。
//
// ⚠️ v0.8.2 实机教训：只试两个路径**全都读不到**（30 秒读了 20 多次全 exists=0）：
//   /var/mobile/Library/Crane/BadgeStore.plist              → 不存在
//   /var/jb/var/mobile/Library/Crane/BadgeStore.plist       → 不存在
// 原因：RootHide 把 CraneSB 装在容器化路径里（实机日志）：
//   /private/var/containers/Bundle/Application/.jbroot-9AB6CCDA0F9265C2/usr/lib/TweakInject/CraneSB.dylib
// 而 CraneSB 的 __cstring 里含 '/var/jb' 前缀、路径又是运行时拼接的，
// 于是它真正的读写目标很可能是：
//   <jbroot前缀>/var/mobile/Library/Crane/BadgeStore.plist
//   即 /private/var/containers/Bundle/Application/.jbroot-XXXX/var/mobile/Library/Crane/...
//
// → 因此这里**不能写死路径**，必须从 locate_crane() 拿到的真实镜像路径动态推导，
//   再叠加若干兜底候选。
static NSString *jbroot_prefix(void) {
    if (!g_cranePath) return nil;
    NSString *p = [NSString stringWithUTF8String:g_cranePath];
    NSRange r = [p rangeOfString:@".jbroot-"];
    if (r.location == NSNotFound) return nil;
    // 从 ".jbroot-" 起，到下一个 "/" 结束（跳过 .jbroot-XXXXXXXX 目录名）
    NSRange slash = [p rangeOfString:@"/"
                                options:0
                                  range:NSMakeRange(r.location, p.length - r.location)];
    if (slash.location == NSNotFound) return nil;
    return [p substringToIndex:slash.location + 1];   // 末尾已含 '/'
}

// 候选路径必须在 locate_crane() 之后才能算（依赖 g_cranePath），
// 所以不再用 dispatch_once 缓存静态数组。
// ⚠️ v0.8 修 v0.6 遗留的类型 bug：返回类型原写成 NSString *，实际返回 NSArray *
//    （clang: warning: incompatible pointer types returning 'NSArray *' from
//     a function with result type 'NSString *'）。返回类型与实际不符属未定义行为。
static NSArray<NSString *> *badge_store_paths(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];

    // ① RootHide 容器前缀（最可能，v0.8.2 实机推导出来的）
    NSString *jp = jbroot_prefix();
    if (jp) {
        [out addObject:[jp stringByAppendingString:@"var/mobile/Library/Crane/BadgeStore.plist"]];
        [out addObject:[jp stringByAppendingString:@"usr/var/mobile/Library/Crane/BadgeStore.plist"]];
    }
    // ② 传统越狱路径（兜底）
    [out addObject:@"/var/mobile/Library/Crane/BadgeStore.plist"];
    [out addObject:@"/var/jb/var/mobile/Library/Crane/BadgeStore.plist"];

    return out;
}

// v0.8.2：**一次性目录探测**。plist 路径猜不出来就别猜了——直接把候选目录
// 的实际内容列出来，用户一眼就能看到 Crane 到底把文件存在哪、叫什么名。
// 只列目录、不做任何写操作，绝无副作用。
static dispatch_once_t g_dumpOnce;
static void dump_crane_dirs_once(void) {
    dispatch_once(&g_dumpOnce, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray<NSString *> *dirs = [NSMutableArray array];
        NSString *jp = jbroot_prefix();
        if (jp) {
            [dirs addObject:[jp stringByAppendingString:@"var/mobile/Library/Crane"]];
            [dirs addObject:[jp stringByAppendingString:@"Library/Crane"]];
        }
        [dirs addObject:@"/var/mobile/Library/Crane"];
        [dirs addObject:@"/var/jb/var/mobile/Library/Crane"];

        for (NSString *d in dirs) {
            NSArray *items = [fm contentsOfDirectoryAtPath:d error:nil];
            if (!items.count) {
                CBFLog(@"[目录探测] %@ → 不存在或为空", d);
                continue;
            }
            CBFLog(@"[目录探测] %@ → %lu 个条目", d, (unsigned long)items.count);
            for (NSString *n in items) {
                NSString *full = [d stringByAppendingPathComponent:n];
                NSDictionary *attr = [fm attributesOfItemAtPath:full error:nil];
                unsigned long long sz = [attr fileSize];
                // ⚠️ v0.8.3 修 bug：v0.8.2 写的是
                //    `BOOL isDir = [fm fileExistsAtPath:full isDirectory:NULL];`
                //    —— 这个方法返回的是「文件是否存在」，不是 isDirectory 的值！
                //    于是所有条目都被误报成 (dir)（实机日志里
                //    「BadgeStore.plist (dir) 306 bytes」就是这么来的）。
                //    正确做法：用属性字典的 NSFileType 判断。
                NSString *type = attr[NSFileType];
                BOOL isDir = [type isEqualToString:NSFileTypeDirectory];
                CBFLog(@"[目录探测]    %@ %@ %llu bytes", n, isDir ? @"(dir)" : @"(file)", sz);
            }
        }
    });
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
// g_cranePath 已在文件头部前置声明（供 badge_store_paths() 使用）

typedef struct {
    uintptr_t getCnt, setCnt, getApp, setExisting, privSet;
} crane_offs_t;

// 1.3.17 symtab 实测偏移（arm64e / arm64 两分片）
static const crane_offs_t kOffArm64e = { 0x6acc, 0x6f54, 0x6c4c, 0x69f8, 0x7c5c };
static const crane_offs_t kOffArm64  = { 0x6734, 0x6b34, 0x689c, 0x6590, 0x7774 };

static const crane_offs_t *cur_offs(void) { return g_arm64e ? &kOffArm64e : &kOffArm64; }

// ★ v0.8 加严镜像匹配。
// 风险：原来只 strstr(name, "CraneSB")，若先匹配到 Crane 的**资源 bundle**
//（也可能叫 CraneSB.xxx 且不是 dylib），slide 与 cpusubtype 都会取错
//   → hook 到错误地址 → 跳进垃圾代码 → SpringBoard 秒崩。
// 现在要求：① 路径以 .dylib 结尾（排除 bundle/资源）；② Mach-O magic 正确；
// ③ 有 __TEXT 段；④ arm64e 分片优先（RootHide A12+ 必为 arm64e）。
static BOOL image_looks_like_cranesb(const char *name) {
    if (!name) return NO;
    size_t n = strlen(name);
    if (n < 9) return NO;                                   // 至少 "CraneSB.dylib"
    if (strcmp(name + n - 6, ".dylib") != 0) return NO;    // 必须 .dylib 结尾
    if (!strstr(name, "CraneSB")) return NO;
    return YES;
}

// ── ⛔ v0.8.1 修正：__TEXT 检查不能作为过滤条件 ──────────────────────
// v0.8 我加了 image_has_text() 当过滤条件，结果**实机全部失效**：
//   跳过无 __TEXT 的镜像: .../.jbroot-9AB6CCDA0F9265C2/.../CraneSB.dylib
//   → 5 次重试全部失败，4 个 C hook 一个都没挂上。
// 原因：RootHide 环境下 dyld 返回的 mach_header 与标准预期不符
//      （RootHide 会改写 dylib 的 header / load commands 来重定向依赖），
//      导致遍历 ncmds 找不到名为 __TEXT 的 segment。
// 但这个镜像**就是正确的 CraneSB**（v0.4~v0.6 用最朴素的 strstr 匹配，
// 实机连续验证成功挂上 4 个 hook）。
//
// → 决策：__TEXT 检查**降级为纯诊断日志**，不再用于跳过任何镜像。
//   真正的过滤条件只保留「路径以 .dylib 结尾」这一条（它能可靠排除
//   Crane 的资源 bundle，且不依赖 header 内容）。
static BOOL image_has_text(const struct mach_header *mh) {
    if (!mh) return NO;
    if (mh->magic != MH_MAGIC_64) return NO;
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmdsize == 0) break;               // 防御：坏 load command
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (strcmp(sg->segname, "__TEXT") == 0) return YES;
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    return NO;
}

static BOOL locate_crane(void) {
    uint32_t n = _dyld_image_count();
    BOOL foundAny = NO;
    uintptr_t bestSlide = 0; BOOL bestIsE = NO;
    const char *bestName = NULL;

    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!image_looks_like_cranesb(name)) continue;

        const struct mach_header *mh = _dyld_get_image_header(i);
        // ⚠️ 仅诊断，不参与过滤（见上方说明）
        BOOL hasText = image_has_text(mh);
        CBFLog(@"候选镜像: %s  magic=0x%08x ncmds=%u __TEXT=%d",
               name, mh ? mh->magic : 0, mh ? mh->ncmds : 0, hasText);

        BOOL isE = mh ? ((mh->cpusubtype & 0x00FFFFFFu) == 2) : NO;
        if (!foundAny) {
            // 第一个合法候选先占位
            foundAny = YES;
            bestSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            bestIsE = isE;
            bestName = name;
        }
        if (isE && !bestIsE) {   // arm64e 分片优先
            bestSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            bestIsE = isE;
            bestName = name;
        }
    }

    if (!foundAny) return NO;
    g_slide = bestSlide;
    g_arm64e = bestIsE;
    g_cranePath = bestName;
    CBFLog(@"找到 CraneSB: %s  slide=%p  arch=%s", bestName, (void *)g_slide,
           bestIsE ? "arm64e" : "arm64");
    return YES;
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
static pthread_mutex_t      g_initLock = PTHREAD_MUTEX_INITIALIZER;

// v0.8.1：原子地「抢占」初始化权。
// 缺陷背景：两阶段重试各自执行 `if (g_inited) return; ... g_inited = YES;`，
// 这是非原子的读-改-写。两个 dispatch_after 块若恰好同时命中，
// 就会**双双进入 install_hooks()**，对同一函数调用两次 MSHookFunction
// → 原实现被替换成我们的实现 → 再替换回来 → 无限递归 → 栈溢出崩溃。
// 现在用互斥锁把「检查 + 置位」合并成一个临界区，保证只有一方成功。
static BOOL claim_init(void) {
    pthread_mutex_lock(&g_initLock);
    BOOL mine = (g_inited == NO);
    if (mine) g_inited = YES;
    pthread_mutex_unlock(&g_initLock);
    return mine;
}

static BOOL is_inited(void) {
    pthread_mutex_lock(&g_initLock);
    BOOL v = g_inited;
    pthread_mutex_unlock(&g_initLock);
    return v;
}

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

#pragma mark - ⛔ 已移除：Crane 官方 crane_resetBadge... API 调用
//
// 原实现（v0.5~v0.7）用 ObjC runtime 定位
//   -crane_resetBadgeOfContainerWithIdentifier:ofApplicationWithIdentifier:
// 然后 `((resetBadge_t)g_imp_reset)(ownerClass, sel, cid, appID)` 调用它。
//
// 这是**导致 v0.7 死机开不了机的直接原因**，因为：
//   1) 该方法是系统私有类的【实例】方法，却被传入 Class 对象当 self，
//      实例方法访问 self 的 ivar 时内存布局完全不匹配 → EXC_BAD_ACCESS；
//   2) 即使 self 传对了，也无法凭空构造出那个系统类的实例；
//   3) 该 owner 类由 Crane 在运行时动态加 category 创建，时机不可控。
//
// v0.8 起本段代码**整体删除**，不再有任何 ObjC 方法调用。
// 若日后要恢复，必须先在真机上单独验证「能否取得合法实例」，绝不能盲调。


// ════════════════════════════════════════════════════════════════════
// ⛔ v0.8 安全底线（完整根因分析见文件头）
// ════════════════════════════════════════════════════════════════════
// 死机根因：把 Class 对象当 self 传给系统私有类的**实例**方法
//          → ivar 越界 → EXC_BAD_ACCESS → SpringBoard 起不来。
// v0.6 因按镜像过滤从未找到该 API 而侥幸不崩；v0.7 去掉过滤后开始执行 → 必崩。
//
// → 本版本**只**使用 MSHookFunction 对 C 函数下钩（改代码，不动方法表），
//   这是 v0.4/v0.5/v0.6 已实机验证、从不崩溃的唯一路径。宁可少修，不可再崩。
// ════════════════════════════════════════════════════════════════════

// 清掉**指定**的单个容器（精确到 cid），不牵连该 app 的其他容器。
// ⚠️ 这里**只**用 C 函数回写 0，**绝不**调用任何 ObjC 方法。
static void purge_one(id appID, id cid) {
    if (!is_string(appID) || !is_string(cid)) return;
    if (orig_SetContainerCount) orig_SetContainerCount(appID, cid, 0);
}

static void purge_containers(id appID) {
    if (!is_string(appID)) return;
    pthread_mutex_lock(&g_lock);
    NSArray *cids = [g_containers[appID] allObjects];
    pthread_mutex_unlock(&g_lock);
    if (!cids.count) return;

    for (id cid in cids) purge_one(appID, cid);
    CBFLog(@"purge 完成 app=%@ 容器数=%lu", appID, (unsigned long)cids.count);
}

#pragma mark - BadgeStore.plist 读取（⛔ v0.8 起只读，不再回写）

// ── v0.8 停用：直接重写 BadgeStore.plist 的 scrub_plist / scrub_value ──────
//
// v0.6/v0.7 曾在清零模式里每 3 秒把整个 BadgeStore.plist 的 NSNumber 全压 0。
// 静态审查发现两个必须停用的理由：
//   1) **数据破坏**：递归压 0 不区分字段，若 plist 里还存了别的数值配置
//      （缩放、动画序号、版本号等），会被一并抹掉且不可恢复。
//   2) **竞争风险**：atomically:YES 会重写整个文件，若此刻 Crane 正在
//      读/写同一个 plist，会出现「Crane 内存缓存」与「磁盘内容」不一致，
//      Crane 下次保存会把我们的修改覆盖回去，甚至写坏 plist。
//
// 替代方案（更安全且更符合原意）：清零一律**通过 Crane 自己的 C 函数**
// orig_SetContainerCount(app, cid, 0) 完成 —— 由 Crane 自己负责持久化，
// 内存缓存与磁盘天然一致，且精确到单个容器，不误伤其他字段。
//
// → 相关代码已全部删除。plist 现在只被**读取**用于诊断与枚举残留。

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

#pragma mark - 启动清零模式

// v0.8 安全加固：plist 遍历的**递归深度上限**。
// plist 由 Crane 写入，若出现自引用/异常深的嵌套，无上限递归会耗尽栈
//   → EXC_BAD_ACCESS → SpringBoard 崩溃（与 v0.7 死机同类风险）。
// 实际嵌套只有 2~4 层，8 层上限已远远够用。
#define SCRUB_MAX_DEPTH 8

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
static NSMutableDictionary *g_harvested = nil;   // "appID|cid" -> @YES
static pthread_mutex_t g_harvestLock = PTHREAD_MUTEX_INITIALIZER;

// v0.8 安全加固（并发崩溃）：schedule_zero_mode 在 30 秒内往**同一个 global
// concurrent queue** 排了 11 个 dispatch_after 块，它们**可能并行执行**。
// v0.6/v0.7 中 g_harvested 是裸 NSMutableDictionary 并发读写
//   → NSMutableDictionary 非线程安全 → 偶发 EXC_BAD_ACCESS（同样是 SpringBoard 崩溃）。
// 现所有读写都在 g_harvestLock 下完成，且判重移入锁内，避免重复登记。
static BOOL harvest_claim(NSString *appID, NSString *cid) {
    NSString *pair = [NSString stringWithFormat:@"%@|%@", appID, cid];
    pthread_mutex_lock(&g_harvestLock);
    BOOL isNew = (g_harvested[pair] == nil);
    if (isNew) g_harvested[pair] = @YES;
    pthread_mutex_unlock(&g_harvestLock);
    return isNew;
}

static unsigned long harvest_count(void) {
    pthread_mutex_lock(&g_harvestLock);
    unsigned long n = (unsigned long)g_harvested.count;
    pthread_mutex_unlock(&g_harvestLock);
    return n;
}

// v0.8 安全加固：深度上限（与 scrub_value 同理，防止栈溢出崩溃）
static void walk_plist_depth(id node, NSString *curApp, NSString *curCID, int depth) {
    if (depth > SCRUB_MAX_DEPTH) return;            // 超深：直接剪枝
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)node;
        for (id k in d) {
            NSString *key = [k isKindOfClass:[NSString class]] ? k : nil;
            id v = d[k];
            NSString *nApp = curApp, *nCID = curCID;
            if (key && looks_like_bundle_id(key))       { nApp = key; nCID = nil; }
            else if (key && looks_like_container_id(key)) { nCID = key; }
            walk_plist_depth(v, nApp, nCID, depth + 1);
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        // 数组：元素若是字典则继承当前上下文
        for (id e in (NSArray *)node) walk_plist_depth(e, curApp, curCID, depth + 1);
    } else if ([node isKindOfClass:[NSNumber class]]) {
        long long n = [(NSNumber *)node longLongValue];
        if (n != 0 && curApp && curCID) {
            if (harvest_claim(curApp, curCID)) {
                remember_container(curApp, curCID);
                CBFLog(@"从 plist 发现残留: app=%@ cid=%@ count=%lld", curApp, curCID, n);
            }
        }
    }
}
static void walk_plist(id node, NSString *curApp, NSString *curCID) {
    walk_plist_depth(node, curApp, curCID, 0);
}

// v0.8 安全加固：g_harvested 的创建也要在锁内 + dispatch_once，
// 避免两个并行的 harvest_from_plist 同时赋值。
static void harvest_init_once(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_harvested = [NSMutableDictionary dictionary];
    });
}

static void harvest_from_plist(void) {
    harvest_init_once();
    // v0.8：先存到局部变量再遍历。for...in 直接写 badge_store_paths()
    // 会让编译器报「collection expression type 'NSString *' may not respond to
    // countByEnumeratingWithState:...」（类型来自旧的错误声明）。
    NSArray<NSString *> *paths = badge_store_paths();
    for (NSString *p in paths) {
        NSDictionary *d = load_badge_store(p);
        if (!d) continue;
        walk_plist(d, nil, nil);
    }
}

// 只 purge「启动前从 plist 扫出来的历史残留」，**不动**启动后新消息的容器。
// v0.6 实测教训：原来 purge_all_known() 直接遍历 g_containers，
// 而 g_containers 会被 rep_GetContainerCount 不断填入「新消息容器」，
// 导致用户开机后新到的未读被清掉（日志里 count=1/2/3 被依次吞掉）。
//
// v0.8 安全加固：遍历 g_harvested 时先在锁内**快照**出 pair 数组，
// 再在锁外 purge —— 避免持锁期间调用 orig_SetContainerCount
// （那是 Crane 自己的函数，可能回调我们的 rep_SetContainerCount → 再次抢锁 → 死锁）。
static void purge_harvested_only(void) {
    pthread_mutex_lock(&g_harvestLock);
    NSArray *pairs = [g_harvested allKeys];
    pthread_mutex_unlock(&g_harvestLock);
    if (!pairs.count) return;

    for (NSString *pair in pairs) {
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
    CBFLog(@"启动清零：plist 历史残留 %lu 个 (app,cid) 组合", harvest_count());

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    for (int i = 0; i < ZERO_MODE_SECONDS / 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 3.0 * NSEC_PER_SEC)), q, ^{
            if (!g_zeroMode) return;
            harvest_from_plist();      // 随时抓 Crane 又写回去的历史残留
            purge_harvested_only();    // 只清历史残留，不碰新消息
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ZERO_MODE_SECONDS * NSEC_PER_SEC)), q, ^{
        harvest_from_plist();
        purge_harvested_only();
        g_zeroMode = NO;
        CBFLog(@"启动清零模式结束，已恢复正常计数");
    });
}

#pragma mark - C 函数替换

static unsigned long long rep_GetContainerCount(id appID, id containerID, unsigned long long flag) {
    unsigned long long cnt = orig_GetContainerCount ? orig_GetContainerCount(appID, containerID, flag) : 0;
    remember_container(appID, containerID);
    if (cnt > 0) {
        // ★ v0.8.3 新增诊断：快捷菜单（_crane_replacementMenu @0xfb88 与
        //   _initApplicationShortcutLateHooks_12Down @0x129e0）都调用本函数。
        //   实机日志里「抑制容器角标」只在清零模式出现，说明平时 Crane
        //   很少走这条读路径 —— 需要确认快捷菜单究竟读不读这里。
        CBFLog(@"[读] GetContainerCount app=%@ cid=%@ → %llu", appID, containerID, cnt);
    }
    if (cnt > 0 && (g_zeroMode || is_cleared(appID))) {
        CBFLog(@"抑制容器角标 %llu app=%@ cid=%@ zero=%d", cnt, appID, containerID, g_zeroMode);
        return 0;
    }
    return cnt;
}

static unsigned long long rep_GetAppCount(id appID, unsigned long long flag) {
    unsigned long long cnt = orig_GetAppCount ? orig_GetAppCount(appID, flag) : 0;
    if (cnt > 0) CBFLog(@"[读] GetAppCount app=%@ → %llu", appID, cnt);
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

    // ★ v0.8.3 新增诊断：这是 Crane **写入** per-container 角标缓存的唯一入口。
    // v0.8.1/v0.8.2 实机日志里这一行**一次都没出现**，说明微信清角标的写动作
    // 完全没走这个 C 函数 —— 快捷菜单的红点残留必然来自别处。
    // 必须把它打出来才能确定 Crane 内部到底用哪条路更新缓存。
    CBFLog(@"[写] SetContainerCount app=%@ cid=%@ count=%llu", appID, containerID, count);

    if (orig_SetContainerCount) orig_SetContainerCount(appID, containerID, count);
}

static void rep_PrivSetBadge(id self, SEL _cmd, id badgeNumberObj, id bundleID, id completion) {
    long long v = -1;
    if (badgeNumberObj && [badgeNumberObj respondsToSelector:@selector(longLongValue)])
        v = [badgeNumberObj longLongValue];

    // ★ v0.8.3 诊断细化：v 才是「用户点了已读」的真实信号。
    // 实机日志里 v>0（未读 1~6）与 v==0（已读）都会走这里，
    // 微信清角标时 Crane 走的是 0x7db0「直接透传」分支 —— 系统角标置 0，
    // 但 Crane 的 per-container 缓存没动 → 快捷菜单仍显示历史值。
    // 这里在 v==0 时把 purge 的实际结果打出来，确认是否真的写下去了。
    if (v == 0) {
        NSUInteger before = 0;
        pthread_mutex_lock(&g_lock);
        before = [g_containers[bundleID] count];
        pthread_mutex_unlock(&g_lock);
        purge_containers(bundleID);
        CBFLog(@"★ 清零信号 v=0 app=%@ 已知容器=%lu", bundleID, (unsigned long)before);
        mark_cleared(bundleID, YES);
    } else {
        CBFLog(@"  非清零信号 v=%lld app=%@", v, bundleID);
        if (v > 0) mark_cleared(bundleID, NO);
    }
    if (orig_PrivSetBadge) orig_PrivSetBadge(self, _cmd, badgeNumberObj, bundleID, completion);
}

#pragma mark - ⛔ 已移除：ObjC 方法层 hook（badgeValueForBundleID: 等）
//
// v0.5~v0.7 曾尝试 hook：
//   -badgeValueForBundleID: / -setBadgeValue:forBundleID:
// 并调用 class_replaceMethod() 改写系统私有类的方法表。
//
// 判定为**高危**并在 v0.8 全部移除，原因：
//   1) 这两个方法的 owner 是**系统私有类**，Crane 用 category 动态添加；
//      owner 类何时创建、何时被替换都不确定；
//   2) class_replaceMethod() 会**永久改写该类的方法表**，影响面不限于 Crane，
//      一旦命中判断错误（例如同名 selector 属于系统原生实现），
//      就会破坏 SpringBoard 自身逻辑 → 启动崩溃；
//   3) 实机日志显示 Crane 实际是通过 C 函数
//      (_badgeCountStoreGetContainerCount / GetAppCount) 走角标逻辑，
//      ObjC 这层 hook 的**边际收益远小于风险**。
//
// 结论：只保留 C 函数层 hook（已在 v0.4/v0.5/v0.6 实机验证不崩）。


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

    // v0.8：不再调用任何 ObjC 方法（曾导致死机，见文件头安全声明）
    CBFLog(@"初始化完成（仅 C 函数层 hook）。日志路径 %@", g_logPath);

    // v0.8.2：立刻把候选目录内容打出来。
    // v0.8.1 实机日志显示四个候选 plist 路径全是 exists=0，
    // 与其继续猜路径，不如让用户从日志里一眼看到 Crane 的真实数据在哪。
    // dump_crane_dirs_once 内部有 dispatch_once，只执行一次；纯只读，无副作用。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        dump_crane_dirs_once();
    });
}

__attribute__((constructor)) static void CBFInit(void) {
    @autoreleasepool {
        CBFLogInit();
        CBFLog(@"==== CraneBadgeFix v0.8.3 加载（保守安全版，仅 C 函数层 hook）====");
        resolve_substrate();
        if (!pMSHookFunction) { CBFLog(@"substrate 不可用，退出"); return; }

        g_clearedApps = [[NSMutableSet alloc] init];
        g_containers  = [[NSMutableDictionary alloc] init];

        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

        // v0.8.1：重试改为**两阶段**。
        // 缺陷背景：v0.8 只排了 5 次（0/0.5/1.5/3/6 秒）就永久放弃，
        // 实机恰好在这几次里都没匹配上 → 补丁全程无效且不会自愈。
        // 设备负载高、或 CraneSB 注入稍晚时，7 秒窗口远远不够。
        //
        // 第一阶段：密集重试，覆盖前 20 秒（大多数情况在此命中）。
        const double early[] = { 0.0, 0.5, 1.5, 3.0, 6.0, 10.0, 15.0, 20.0 };
        size_t nEarly = sizeof(early) / sizeof(early[0]);
        for (size_t i = 0; i < nEarly; i++) {
            const double d = early[i];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), q, ^{
                if (is_inited()) return;                 // 别人已装好
                if (!locate_crane()) {
                    CBFLog(@"尚未找到 CraneSB，%.1fs 处重试（第一阶段）", d);
                    return;
                }
                if (!claim_init()) return;                // 竞态：别人抢先了
                install_hooks();
                schedule_zero_mode();
            });
        }

        // 第二阶段：稀疏重试，持续到 5 分钟。每 15 秒一次。
        // 这样即使 CraneSB 加载很晚，补丁最终也能挂上，无需重启手机。
        for (int k = 0; k < 18; k++) {
            const double d = 30.0 + k * 15.0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), q, ^{
                if (is_inited()) return;
                if (locate_crane()) {
                    if (!claim_init()) return;            // 竞态：别人抢先了
                    CBFLog(@"第二阶段终于找到 CraneSB（%.1fs），开始安装 hook", d);
                    install_hooks();
                    schedule_zero_mode();
                } else {
                    CBFLog(@"第二阶段：仍未找到 CraneSB（%.1fs），继续等待", d);
                }
            });
        }
    }
}

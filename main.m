/*
 * CraneBadgeFix v0.9.1（回归修复 + 三处隐患根治）
 * ==============================
 * 修复 Crane 1.3.17 多开应用（微信等）「消息已读后，图标角标已消失、
 * 但快捷菜单（Haptic Touch）仍残留 per-container 未读数」。
 *
 * ════════════════════════════════════════════════════════════════════
 * ★★★ v0.9.1：v0.9.0 引入严重回归，本版优先修复，并推翻 v0.9.0 的一个错误判据
 * ════════════════════════════════════════════════════════════════════
 * 用户实测反馈：「这次图标角标收到消息都没有红点了」。
 *
 * v0.9.0 实机日志（决定性）：
 *   23:45:18  进入启动清零模式 30 秒
 *   23:45:46  [写] SetContainerCount count=1     ← 用户收到第 1 条新消息（启动后 28 秒）
 *   23:45:46  [读] GetContainerCount → 1
 *   23:45:46  抑制容器角标 1 app=… zero=1      ← 被压成 0，红点不亮
 *   23:45:46  [写] SetContainerCount count=2     ← 第 2 条
 *   23:45:46  抑制容器角标 2 app=… zero=1      ← 也被压成 0
 *
 * ── 根因 1（直接原因）：zeroMode 一刀切压制 ──────────────────────
 *   v0.9.0 的 rep_GetContainerCount / rep_GetAppCount 写的是：
 *       if (cnt > 0 && (g_zeroMode || is_cleared(appID))) return 0;
 *   zeroMode 为真期间，**所有容器**的所有非零 count 都被压成 0，
 *   不区分「新消息」与「历史残留」。用户恰好在启动清零窗口内（30 秒）收到消息，
 *   于是真实新消息和图标红点一起被吞。
 *   → 本版拆成两个独立条件：zeroMode 只压制「plist 基线未变」的容器，
 *     有新消息的一律放过（zero_mode_should_suppress / app_has_live_unread）。
 *
 * ── 根因 2：harvest 把新消息误登记为残留 ─────────────────────────
 *   schedule_zero_mode 每 3 秒重跑 harvest_from_plist()，
 *   而用户在此时正收新消息 → Crane 把 count=1 写进 plist
 *   → harvest 把这个**新消息容器**登记成「历史残留」→ purge 随即清零。
 *   → 本版 purge 前**重读 plist** 对比基线（见 harvest_claim / snapshot_current_counts）。
 *
 * ═══ ★ v0.9.0 的保护判据本身是错的，本版推翻 ═════════════════════
 * v0.9.0 用「count 曾经 > 0 ⇒ 是真实新消息」来保护。**这个判据不成立**：
 *   历史残留的 count 本身就 > 0。若 Crane 启动初期把 plist 残留回灌进内存
 *   （走 SetContainerCount），每个残留都会被记成「新消息」而受保护
 *   → **一个残留都清不掉** → v0.8.2 刚打通的持久化清零被彻底废掉。
 *   换句话说：用 v0.9.0 修回归，会把问题从「新消息被吞」变成「残留清不掉」，
 *   两者都不可接受。
 *
 * → 唯一能区分二者的信息是**时间**：残留 = harvest 那一刻就在 plist 里的，
 *   新消息 = 那之后才写进去的。所以 harvest 时把 count 存成**基线**，
 *   purge 前重读 plist 比对：cur > baseline ⇒ 新消息，不碰；cur ≤ baseline ⇒ 残留，清。
 *   这个判据不依赖「是否非零」，因此没有 v0.9.0 那个反噬。
 *
 * ═══ 顺带根治的两个隐患（v0.8.3 起就潜伏，仅靠未读下降未触发而侥幸无害）═══
 * 隐患 A：note_count_change 的**语义混用**
 *   g_lastCount 以 appID 为 key，却被两个语义完全不同的来源共用：
 *     rep_PrivSetBadge      传「该 app 的**总**未读数」（微信 badgeNumber）
 *     rep_SetContainerCount 传「**单容器**未读数」
 *   放同一张表比大小 ⇒ 必然误判下降。日志里 `v=5`（总数）紧跟
 *   `count=2`（单容器）会被当成「5→2 巨幅下降」。
 *   → 本版按通道隔离：key 改为 "A|appID" / "C|appID|cid"，
 *     且**只有 app 总数通道（A）允许触发 purge**，单容器通道只记账。
 * 隐患 B：未读下降时 purge_containers(appID) 清掉该 app 的**所有**容器
 *   用户读掉 A 会话时，B/C 会话里还没看的未读会被一起清零 → 吞消息。
 *   → 本版改为 purge_app_residuals()：只清「harvest 登记过 且 当前未超基线」
 *     的容器，有活跃未读的一律保留。
 *
 * ⚠️ v0.9.1 未新增任何 hook，未新增任何 ObjC 运行时操作，
 *   判据数据全部来自「只读 plist」+「Crane 自己的 C 写函数」，风险面与 v0.9.0 相同。
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
 * ── v0.9.0：找到「快捷菜单」的第一个真根因并修复 ────────────────────
 * v0.8.3 实机日志第一次看清了完整数据流（23:37:07~23:37:20）：
 *
 *   非清零信号 v=1  →  [写] SetContainerCount count=1  →  [读] GetContainerCount → 1
 *   非清零信号 v=2  →  [写] count=2  →  [读] → 2
 *   非清零信号 v=3  →  [写] count=3  →  [读] → 3
 *   非清零信号 v=4  →  [写] count=4  →  [读] → 4
 *   非清零信号 v=3  →  [写] count=3  →  [读] → 3     ← 下降！
 *   非清零信号 v=4  →  [写] count=4  →  [读] → 4
 *   非清零信号 v=5  →  [写] count=5  →  [读] → 5
 *   非清零信号 v=2  →  [写] count=2  →  [读] → 2     ← 大幅下降
 *   ...（共 20 次）
 *   [23:37:40] [读] GetContainerCount → 5    ← 无写入，纯读取（快捷菜单在轮询）
 *   [23:37:55] [读] GetContainerCount → 5
 *   [23:38:04] [读] GetContainerCount → 5
 *
 * 两个决定性结论：
 *   1) 写路径确实走 _badgeCountStoreSetContainerCount（我 v0.8.3 那句
 *      「写路径不走这里」是**错的** —— 当时只是这个函数没打日志）。
 *      读路径确实走 GetContainerCount（最后三行无写入的纯读取 = 菜单轮询）。
 *   2) ★★ **微信全程没发过一次 badgeNumber=0**（最低只到 v=1），
 *      但它的未读数**会下降**（4→3、5→2）—— 那就是用户在读消息。
 *
 * → 第一个真根因：is_cleared 只在 v==0 时置位，等的是一个**永远不来的信号**，
 *   所以快捷菜单永远不被抑制。
 *
 * v0.9.0 修复（纯 C 层数据流，不碰任何 ObjC 方法）：
 *   新增 note_count_change()：记住每个 app 上次上报的未读数，
 *     · 新值 < 上次值 → 用户已读 → purge 该 app 的容器 + mark_cleared(YES)
 *     · 新值 = 上次值 → 同一事件的第二个上报，跳过（去重，防重复 purge）
 *     · 新值 > 上次值 → 新消息 → mark_cleared(NO) 恢复正常计数
 *   时机选在 rep_PrivSetBadge（系统设置角标的入口）：在它把新值写入 Crane 之前
 *   先清残留，既不吞掉即将到来的新消息（写入仍透传），又让后续菜单读取拿到 0。
 *
 * 同时新增 setExisting 探针：hook `_setExistingBadgeCountForApplication`@0x69f8
 *   （symtab 里一直存在但从未 hook）。本版**只打日志不改行为** ——
 *   该函数可能同时服务图标角标路径，贸然改返回值会让图标角标也挂掉。
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
static BOOL is_string(id o);   // 前置声明：实现在下方「状态」段，dump_crane_dirs_once 要用

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

// ── v0.9.0：新增 hook _setExistingBadgeCountForApplication ────────────
//
// 背景（v0.8.3 实机日志的决定性证据）：
//   写路径确认走 _badgeCountStoreSetContainerCount（`[写] SetContainerCount` 大量出现）；
//   读路径确认走 _badgeCountStoreGetContainerCount（快捷菜单在轮询它，见 23:37:40/55/38:04）；
//   **但微信全程没发过一次 badgeNumber=0** —— 最低只到 v=1。
//   而 is_cleared 标记只在 v==0 时置位 → 快捷菜单永远不被抑制。
//
// 这是「快捷菜单修不掉」的第一个真正根因：**清零信号永远不来**。
//
// 观察到一个更本质的事实：图标角标清零正确，但 Crane 的 per-container 缓存不清。
// 说明微信是直接调系统 UIKitApplication 的 setBadgeNumber:，
// 而 Crane 只是**旁路读取** per-container 缓存去画快捷菜单 —— 它自己不知道用户已读。
//
// 因此新增 hook `_setExistingBadgeCountForApplication`（symtab 偏移 0x69f8）：
// 从函数名语义看，它是「给某 app 设置现有角标数」的入口，
// 极可能是 Crane 在菜单展示前把缓存值写进去的地方。
// 本版**先只加日志**探明它的签名与调用时机（参数个数/类型/值），
// 确认后再决定是压 0 还是改返回值 —— 不盲目下钩改行为。
typedef void (*setExisting_t)(id self, SEL _cmd, id appID, unsigned long long count);
static setExisting_t orig_SetExistingBadge = NULL;

// v0.9.0 记录最近一次观察到的 setExisting 调用，用于诊断对照
static unsigned long long g_lastExistingCount = 0;
static NSString         *g_lastExistingApp = nil;

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

// ════════════════════════════════════════════════════════════════════
// v0.9.0：「未读数下降」= 用户已读的可靠信号
// ════════════════════════════════════════════════════════════════════
// v0.8.3 实机日志的决定性发现：**微信全程没发过一次 badgeNumber=0**。
// 23:37:07~23:37:20 共 20 次调用的 v 值是 1,2,3,4,3,4,5,5,2,3,4,3,4,5,5…
//
// 注意这个序列：**它会下降**（4→3、5→2）。这不是噪声 ——
// 用户每读掉一批消息，微信上报的未读总数就下降。
// 而我们此前只在 v==0 时置 is_cleared，等一个永远不来的信号 → 快捷菜单永不抑制。
//
// 修复思路（保守）：
//   记住该 app 上一次上报的未读数 vPrev；
//   当新值 vNew < vPrev 时，说明用户读了东西 → 把 Crane 的 per-container
//   缓存按差值回收（purge），并把已读数记下来；
//   当 vNew > vPrev（新消息）时，撤销清零标记，恢复正常显示。
//
// 为什么这个判据安全：
//   ① 下降只可能由「用户已读」造成（新消息只会让数字变大）；
//   ② 差值回收精确到「少了多少条就清多少」，不会吞掉真实新消息；
//   ③ 不依赖任何 ObjC 方法调用，纯 C 层数据流。
// ⚠️ v0.9.1 修一个 v0.8.3 就潜伏的**语义混用**缺陷：
//   这个字典的 key 只有 appID，于是被**两个语义完全不同的来源共用**：
//     · rep_PrivSetBadge      传的是「该 app 的**总**未读数」（微信上报的 badgeNumber）
//     · rep_SetContainerCount 传的是「**单个容器**的未读数」
//   两者放进同一张表比大小 → 必然误判下降。
//   实机日志里 `非清零信号 v=5` 紧跟着 `[写] SetContainerCount count=2` 就是
//   总数 5 之后写入单容器 2 → 被当成「5→2 巨幅下降」→ 误 purge。
//
// → 现按 key 前缀分开记账：A|appID（总数）与 C|appID|cid（单容器）。
//   「用户已读」的判定**只信任总数通道**（rep_PrivSetBadge），
//   因为那才是微信对「整条会话已读」的表态；
//   单容器通道只做诊断记录，不触发 purge。
static NSMutableDictionary *g_lastCount = nil;    // "A|appID" / "C|appID|cid" -> @(上次未读数)

// ⚠️ v0.9.0 去重：同一次未读事件会被 rep_PrivSetBadge 与 rep_SetContainerCount
// **各上报一次同一个值**（实机日志里 `非清零信号 v=2` 与
// `[写] SetContainerCount count=2` 是紧挨着的一对）。
// 若两边都独立记一次「上次值」，第二条会把自己当成 0 来比 → 误判下降 → 重复 purge。
// 解法：**只有当新值与上次记录不同**才算一次真实变化；相同值直接跳过。
// 这样 2 → 2 不会被判成 2→0 的下降。

// 返回 YES 表示检测到「未读数下降」（用户已读）
//
// ⚠️ v0.9.1：key 改为**带前缀的通道标识**。
//   channel = @"A"（app 级总数，来自微信 badgeNumber）或 @"C"（单容器计数）。
//   不同通道必须分开记账，否则「总数 5」与「单容器 2」放一起比会误判下降。
static BOOL note_count_change(id appID, unsigned long long vNew, NSString *channel,
                              unsigned long long *deltaOut) {
    if (!is_string(appID) || !is_string(channel)) return NO;
    // ⚠️ v0.9.0 并发加固：rep_PrivSetBadge 与 rep_SetContainerCount 可能被不同线程
    //   同时进入。原来的 `if (!g_lastCount) g_lastCount = [NSMutableDictionary dictionary];`
    //   是「检查后创建」，两个线程会各建一个 → 后者覆盖前者 → 状态丢失。
    //   改用 dispatch_once 保证唯一初始化。
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_lastCount = [NSMutableDictionary dictionary]; });

    NSString *key = [NSString stringWithFormat:@"%@|%@", channel, appID];

    pthread_mutex_lock(&g_lock);
    NSNumber *prevNum = g_lastCount[key];
    unsigned long long vPrev = prevNum ? prevNum.unsignedLongLongValue : vNew;
    BOOL sameAsPrev = (vNew == vPrev);          // 同一事件的第二个上报
    g_lastCount[key] = @(vNew);
    BOOL dropped = (!sameAsPrev && vNew < vPrev);
    pthread_mutex_unlock(&g_lock);

    if (deltaOut) *deltaOut = dropped ? (vPrev - vNew) : 0;
    if (dropped) CBFLog(@"↓ 未读下降[%@] app=%@ %llu → %llu", channel, appID, vPrev, vNew);
    return dropped;
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
static NSMutableDictionary *g_harvested = nil;   // "appID|cid" -> @(harvest 时的 count 基线)
static pthread_mutex_t g_harvestLock = PTHREAD_MUTEX_INITIALIZER;

// ── v0.9.1：区分「历史残留」与「真实新消息」的唯一可靠判据 = plist 基线 ────
//
// v0.9.0 曾试图用「count 曾经 > 0 ⇒ 是新消息」来保护，**这个判据不成立**：
//   harvest 从 plist 扫到的历史残留本身也 > 0；Crane 启动初期若把残留回灌
//   进内存（走 SetContainerCount），就会被记成「新消息」而受保护，
//   结果是**每个历史残留都清不掉** —— 持久化清零功能直接废掉。
// v0.8 安全加固（并发崩溃）：schedule_zero_mode 在 30 秒内往**同一个 global
// concurrent queue** 排了 11 个 dispatch_after 块，它们**可能并行执行**。
// v0.6/v0.7 中 g_harvested 是裸 NSMutableDictionary 并发读写
//   → NSMutableDictionary 非线程安全 → 偶发 EXC_BAD_ACCESS（同样是 SpringBoard 崩溃）。
// 现所有读写都在 g_harvestLock 下完成，且判重移入锁内，避免重复登记。
//
// 真正能区分「残留」与「新消息」的唯一可靠判据是**时间**：
//   残留 = harvest 那一刻已经在 BadgeStore.plist 里的；
//   新消息 = 那之后才被 Crane 写进去的（count 被抬高）。
// 所以 harvest 时把当时的 count 存成**基线**，purge 前重读 plist 拿当前值对比：
//   当前值 >  基线 → 期间有新消息写进来 → 绝不压制、绝不 purge
//   当前值 <= 基线 → 仍是原封不动的旧残留     → 可以清
// 这个判据只用「只读 plist + Crane 自己的 C 写函数」，不新增任何 hook，风险极低。
//
// ⚠️ v0.9.0 曾在这里用「count 曾经 > 0 ⇒ 是新消息」来保护，**判据不成立**：
//   历史残留的 count 本身就 > 0；Crane 启动初期若把 plist 残留回灌进内存，
//   每个残留都会被记成「新消息」而受保护 → 一个都清不掉 → 持久化清零被废掉。
static BOOL harvest_claim(NSString *appID, NSString *cid, long long baseline) {
    NSString *pair = [NSString stringWithFormat:@"%@|%@", appID, cid];
    pthread_mutex_lock(&g_harvestLock);
    BOOL isNew = (g_harvested[pair] == nil);
    // ⚠️ 只在**首次**登记时记录基线。后续每 3 秒重跑 harvest 时若覆盖基线，
    //   基线会被新消息顶高，残留就永远等不到「当前值 <= 基线」而被误当新消息保护。
    if (isNew) g_harvested[pair] = @(baseline);
    pthread_mutex_unlock(&g_harvestLock);
    return isNew;
}

// 该 (app,cid) 是否在启动 harvest 中被登记为历史残留；outBaseline 返回基线值
static BOOL residual_baseline(NSString *appID, NSString *cid, long long *outBaseline) {
    if (!is_string(appID) || !is_string(cid)) return NO;
    NSString *pair = [NSString stringWithFormat:@"%@|%@", appID, cid];
    pthread_mutex_lock(&g_harvestLock);
    NSNumber *n = g_harvested[pair];
    pthread_mutex_unlock(&g_harvestLock);
    if (!n) return NO;
    if (outBaseline) *outBaseline = n.longLongValue;
    return YES;
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
            // ★ v0.9.1：把 count 当作**基线**登记（v0.9.0 这里是 @YES，无法区分残留与新消息）
            if (harvest_claim(curApp, curCID, n)) {
                remember_container(curApp, curCID);
                CBFLog(@"从 plist 发现残留: app=%@ cid=%@ 基线count=%lld", curApp, curCID, n);
            }
        }
    }
}
static void walk_plist(id node, NSString *curApp, NSString *curCID) {
    walk_plist_depth(node, curApp, curCID, 0);
}

// ★★ v0.9.1：把 plist 解析成 "app|cid" -> @(count) 的**当前值快照**。
// 与 walk_plist_depth 同构（同样的特征识别 + 同样的深度上限），
// 区别只在于「收集」而非「登记残留」。
static void collect_counts_depth(id node, NSString *curApp, NSString *curCID,
                                 int depth, NSMutableDictionary *out) {
    if (depth > SCRUB_MAX_DEPTH) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)node;
        for (id k in d) {
            NSString *key = [k isKindOfClass:[NSString class]] ? k : nil;
            id v = d[k];
            NSString *nApp = curApp, *nCID = curCID;
            if (key && looks_like_bundle_id(key))       { nApp = key; nCID = nil; }
            else if (key && looks_like_container_id(key)) { nCID = key; }
            collect_counts_depth(v, nApp, nCID, depth + 1, out);
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id e in (NSArray *)node) collect_counts_depth(e, curApp, curCID, depth + 1, out);
    } else if ([node isKindOfClass:[NSNumber class]]) {
        if (!curApp || !curCID) return;
        long long n = [(NSNumber *)node longLongValue];
        NSString *pair = [NSString stringWithFormat:@"%@|%@", curApp, curCID];
        NSNumber *prev = out[pair];
        // 多路径/多处出现时取最大值：宁可高估成「新消息」也不误清真实新消息
        if (!prev || n > prev.longLongValue) out[pair] = @(n);
    }
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

// ★★ v0.9.1：重读 BadgeStore.plist，取出每个 (app,cid) 的**当前**未读数。
// 这是「残留 vs 新消息」判据的数据来源。
//
// 为什么必须重读而不是依赖内存里的计数：
//   · harvest 时的基线只代表「启动那一刻」的值；
//   · 之后用户每收一条新消息，Crane 都会把更大的 count 写进 plist；
//   · 只有重读才能知道「现在比基线大了」→ 说明是新消息，不能动。
//
// ⚠️ 深度上限同样生效（复用 walk_plist_depth），纯只读，无副作用。
// ⚠️ 同一 pair 若在多个候选路径都出现，以**最大** count 为准（保守：宁可当成新消息不保护）。
static void snapshot_current_counts(NSMutableDictionary *out) {
    if (!out) return;
    NSArray<NSString *> *paths = badge_store_paths();
    for (NSString *p in paths) {
        NSDictionary *d = load_badge_store(p);
        if (!d) continue;
        collect_counts_depth(d, nil, nil, 0, out);
    }
}

// ★★ v0.9.1：purge_containers 的**保守替代品**，用于「未读下降即已读」路径。
//
// v0.9.0 在 rep_PrivSetBadge 里调 purge_containers(appID) 清掉该 app 的**所有**容器，
// 这是个会误伤用户的动作：用户读掉 A 会话的同时，B/C 会话里还没看的未读
// 会被一起清零 → 吞消息。而"下降就清全部"在本场景里毫无必要：
// 用户已读之后该 app 的剩余未读本来就是想看的，只清**旧残留**就够了。
//
// 现在的策略（三重保护，任一命中即跳过清零）：
//   ① 只处理在启动 harvest 中登记过的容器（不是残留的一律不动）；
//   ② 重读 plist，若当前 count **高于**基线 → 期间来了新消息 → 跳过；
//   ③ 当前 count 为 0 → 已经清过了 → 跳过（避免无谓写盘）。
// 返回实际清理的容器数。
static unsigned long long purge_app_residuals(id appID) {
    if (!is_string(appID)) return 0;

    pthread_mutex_lock(&g_harvestLock);
    NSArray *pairs = [g_harvested allKeys];
    pthread_mutex_unlock(&g_harvestLock);
    if (!pairs.count) return 0;

    NSString *prefix = [appID stringByAppendingString:@"|"];
    NSMutableArray *mine = [NSMutableArray array];
    for (NSString *p in pairs) if ([p hasPrefix:prefix]) [mine addObject:p];
    if (!mine.count) {
        // 一个残留都没登记 → 用已知容器兜底（首次启动、plist 为空的场景）
        pthread_mutex_lock(&g_lock);
        NSArray *cids = [g_containers[appID] allObjects];
        pthread_mutex_unlock(&g_lock);
        for (id cid in cids) purge_one(appID, cid);
        return (unsigned long long)cids.count;
    }

    NSMutableDictionary *cur = [NSMutableDictionary dictionary];
    snapshot_current_counts(cur);

    unsigned long long n = 0;
    for (NSString *p in mine) {
        NSArray *kv = [p componentsSeparatedByString:@"|"];
        if (kv.count != 2) continue;
        long long baseline = 0;
        if (!residual_baseline(kv[0], kv[1], &baseline)) continue;

        NSNumber *curNum = cur[p];
        long long curNow = curNum ? curNum.longLongValue : 0;
        if (curNow == 0) continue;          // ③ 已清过
        if (curNow > baseline) continue;    // ② 有活跃新消息 → 保留

        purge_one(kv[0], kv[1]);
        n++;
    }
    return n;
}

// 只 purge「启动 harvest 时就在 plist 里、且此后 count 未被抬高」的容器。
//
// ★★ v0.9.1 重写（v0.9.0 的保护判据不成立，见 harvest_claim 的说明）：
//   不再问「这个容器有没有非零 count」（残留本身也非零，问不出区别），
//   而是问「**它现在的 count 是不是还等于启动时的基线**」。
//     cur >  baseline → 期间 Crane 写进过新消息 → **跳过，绝不清**
//     cur <= baseline → 仍是原封不动的旧残留     → 清零
// 判据数据来自 snapshot_current_counts()（重读 plist，只读）。
//
// v0.8 安全加固保留：先在锁内**快照**出 pair 数组，再在锁外 purge ——
// 避免持锁期间调用 orig_SetContainerCount（Crane 自己的函数，
// 可能回调我们的 rep_SetContainerCount → 再次抢锁 → 死锁）。
static void purge_harvested_only(void) {
    pthread_mutex_lock(&g_harvestLock);
    NSArray *pairs = [g_harvested allKeys];
    pthread_mutex_unlock(&g_harvestLock);
    if (!pairs.count) return;

    // 重读一次 plist，拿到所有容器的当前值（一次读取，供本轮全部判定使用）
    NSMutableDictionary *cur = [NSMutableDictionary dictionary];
    snapshot_current_counts(cur);

    unsigned long long cleared = 0, skipped = 0;
    for (NSString *pair in pairs) {
        NSArray *kv = [pair componentsSeparatedByString:@"|"];
        if (kv.count != 2) continue;

        long long baseline = 0;
        if (!residual_baseline(kv[0], kv[1], &baseline)) continue;

        NSNumber *curNum = cur[pair];
        long long curCount = curNum ? curNum.longLongValue : 0;

        // ★ 核心判据：当前值高于基线 = 期间来了新消息 → 绝对不碰
        if (curCount > baseline) {
            skipped++;
            CBFLog(@"保护：%@|%@ 有新消息（当前 %lld > 基线 %lld），不清", kv[0], kv[1], curCount, baseline);
            continue;
        }
        purge_one(kv[0], kv[1]);   // 精确到单个容器，不碰该 app 的其他容器
        cleared++;
    }
    CBFLog(@"清零完成：已清 %llu 个残留，保护 %llu 个有新消息的容器", cleared, skipped);
}

// ════════════════════════════════════════════════════════════════════
// v0.9.1 修回归：清零模式吞掉真实新消息（图标角标不显示红点）
// ════════════════════════════════════════════════════════════════════
// v0.9.0 实机日志（用户反馈「收到消息都没有红点了」）：
//
//   23:45:18  进入启动清零模式 30 秒
//   23:45:46  [写] SetContainerCount count=1     ← 用户收到第 1 条新消息
//   23:45:46  [读] GetContainerCount → 1
//   23:45:46  抑制容器角标 1 zero=1              ← 被当残留吞掉！
//   23:45:46  [写] SetContainerCount count=2     ← 第 2 条新消息
//   23:45:46  抑制容器角标 2 zero=1              ← 也被吞掉！
//
// 根因链：
//   1) schedule_zero_mode 每 3 秒重跑 harvest_from_plist()
//   2) 而用户此时正在收新消息 → Crane 把 count=1 写进 plist
//   3) harvest_from_plist 把这个**新消息容器**误登记为「历史残留」
//   4) purge_harvested_only 随即把它清成 0
//   5) rep_GetContainerCount 在 g_zeroMode 期间又对所有非零值返回 0
//   → 图标角标永远不亮
//
// 这正是 v0.6 就发现、v0.7 声称修掉、v0.8 重写时又漏掉的旧 bug 第三次复发。
//
// ★ v0.9.1 修复：**plist 基线对比**，而不是「count 是否非零」
//   残留 = harvest 那一刻已在 plist 里的；
//   新消息 = 那之后 Crane 才写进去的（count 被抬高）。
//   所以只要 harvest 记下基线、purge 前重读 plist 对比，就能精确区分：
//     cur >  baseline → 有新消息 → **不压制、不清零**
//     cur <= baseline → 仍是残留     → 压制、清零
//
// ⚠️ v0.9.0 在这里试过「曾见最大 count > 0 ⇒ 是新消息」，**判据不成立**：
//   历史残留本身也 > 0，Crane 启动初期回灌时会被全部记成「新消息」，
//   结果每个残留都受保护、一个都清不掉 → 持久化清零功能被废掉。
//   基线对比不依赖「是否非零」，因此没有这个反噬。
//
// ★ v0.9.1：原 g_maxSeenCount / note_max_count() 已**整体删除**。
//   它在 v0.9.0 是错误判据的载体；改成基线判据后它没有任何读取方，
//   留着只是个纯占内存的全局变量（实测确认它会作为活跃符号留在产物符号表里）。
//   诊断信息改由下面的日志行直接给出，更直接也更省内存。


// ★★ 读取侧的保护判据（本轮真正的修复点）：
//   zeroMode 期间要压制读数，但**必须放过有真实新消息的容器**。
//
//   注意：这里**不能**简单地「凡是在 g_harvested 里就压制」——
//   因为启动清零窗口内新到的消息，其容器可能**恰好也在** g_harvested 里
//   （harvest 每 3 秒重跑一次，会把 Crane 刚写进去的新消息也登记进去）。
//   所以判据必须是「当前值是否已高于基线」，这只有重读 plist 才知道。
//
//   为避免每次菜单轮询都去读盘（快捷菜单 15 秒轮询一次，30 秒窗口内约 2~3 次，
//   开销可接受），这里用一个轻量缓存：只有 zeroMode 期间才查，窗口一过立即失效。
static BOOL zero_mode_should_suppress(id appID, id containerID, unsigned long long curCount) {
    if (!g_zeroMode) return NO;
    if (!is_string(appID) || !is_string(containerID)) return NO;
    if (curCount == 0) return NO;

    long long baseline = 0;
    if (!residual_baseline(appID, containerID, &baseline)) return NO;   // 不是残留，不归我们管

    // 重读 plist 拿当前值：只有「当前 > 基线」才说明期间来了新消息 → 放过
    NSMutableDictionary *cur = [NSMutableDictionary dictionary];
    snapshot_current_counts(cur);
    NSString *pair = [NSString stringWithFormat:@"%@|%@", appID, containerID];
    NSNumber *curNum = cur[pair];
    long long curNow = curNum ? curNum.longLongValue : (long long)curCount;

    if (curNow > baseline) {
        CBFLog(@"zeroMode 放过：%@|%@ 有新消息（当前 %lld > 基线 %lld）", appID, containerID, curNow, baseline);
        return NO;
    }
    return YES;
}

// 该 app 下是否**至少有一个容器**出现了新消息（当前 count 高于 harvest 基线）。
// 用于 rep_GetAppCount：只要有一个容器有真新消息，就不整体压制图标角标。
static BOOL app_has_live_unread(id appID) {
    if (!is_string(appID)) return NO;

    // 该 app 的所有已知残留容器
    pthread_mutex_lock(&g_harvestLock);
    NSArray *pairs = [g_harvested allKeys];
    pthread_mutex_unlock(&g_harvestLock);
    if (!pairs.count) return NO;

    NSString *prefix = [appID stringByAppendingString:@"|"];
    NSMutableArray *mine = [NSMutableArray array];
    for (NSString *p in pairs) if ([p hasPrefix:prefix]) [mine addObject:p];
    if (!mine.count) return NO;

    // 一次重读 plist，逐个比对基线
    NSMutableDictionary *cur = [NSMutableDictionary dictionary];
    snapshot_current_counts(cur);
    for (NSString *p in mine) {
        NSArray *kv = [p componentsSeparatedByString:@"|"];
        if (kv.count != 2) continue;
        long long baseline = 0;
        if (!residual_baseline(kv[0], kv[1], &baseline)) continue;
        NSNumber *curNum = cur[p];
        long long curNow = curNum ? curNum.longLongValue : 0;
        if (curNow > baseline) {
            CBFLog(@"app_has_live_unread: %@ 有新消息容器 %@|%@（%lld > %lld）", appID, kv[0], kv[1], curNow, baseline);
            return YES;
        }
    }
    return NO;
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
        CBFLog(@"[读] GetContainerCount app=%@ cid=%@ → %llu", appID, containerID, cnt);
    }
    if (cnt == 0) return 0;

    // ★★ v0.9.1 修回归的核心（这行就是 v0.9.0「收到消息没有红点」的直接原因）：
    //   v0.9.0 写的是 `if (cnt > 0 && (g_zeroMode || is_cleared(appID))) return 0;`
    //   —— zeroMode 期间**无条件**把所有容器的非零 count 压成 0，
    //   于是启动清零窗口（30 秒）内到达的真实新消息也一起被吞掉，
    //   实机日志：23:45:46 count=1 → 抑制容器角标 1 zero=1 / count=2 → 抑制 2 zero=1。
    //
    // 现在拆成两个独立条件：
    //   ① zeroMode：只压制「plist 基线未变」的容器（即真正的历史残留），
    //      有新消息的（当前 > 基线）一律放过 → zero_mode_should_suppress()
    //   ② is_cleared：用户已读后的正常压制，保持 v0.8.3 行为不变
    //      （已实机验证图标角标清零正确）。
    if (g_zeroMode && zero_mode_should_suppress(appID, containerID, cnt)) {
        CBFLog(@"抑制残留容器角标 %llu app=%@ cid=%@", cnt, appID, containerID);
        return 0;
    }
    if (is_cleared(appID)) {
        CBFLog(@"抑制容器角标 %llu app=%@ cid=%@（已读标记）", cnt, appID, containerID);
        return 0;
    }
    return cnt;
}

// app 级角标（图标红点）= 各容器求和。
// ⚠️ 这里**不能**用 zeroMode 一刀切压制整个 app：
//   实机日志证明图标角标走 GetAppCount，而 v0.9.0 在 zeroMode 期间把它压 0，
//   直接导致「收到消息图标完全没有红点」。
//   → 改为逐容器压制：只把「历史残留」的容器当 0，
//     有新消息的容器如实计入，图标角标自然就能正常亮起。
//   （GetAppCount 是 Crane 内部求和，无法逐项干预；
//     因此这里只在「该 app 所有已知容器都无新消息」时才整体压制。）
static unsigned long long rep_GetAppCount(id appID, unsigned long long flag) {
    unsigned long long cnt = orig_GetAppCount ? orig_GetAppCount(appID, flag) : 0;
    if (cnt == 0) return 0;
    CBFLog(@"[读] GetAppCount app=%@ → %llu", appID, cnt);

    // ★ v0.9.1：zeroMode 期间，只有当该 app 的**每一个**已知容器都没有新消息时才压制。
    //   只要有一个容器来了新消息，就如实返回，避免吞掉图标角标。
    if (g_zeroMode && !app_has_live_unread(appID)) {
        CBFLog(@"抑制 app 角标 %llu app=%@（清零窗口内、全部为残留）", cnt, appID);
        return 0;
    }
    if (is_cleared(appID)) {
        CBFLog(@"抑制 app 角标 %llu app=%@（已读标记）", cnt, appID);
        return 0;
    }
    return cnt;
}

// ── v0.9.0：setExisting 的探针实现 ────────────────────────────────────
// ⚠️ 本版**只记录不修改**：先确认签名与调用时机，再决定压不压 0。
//   贸然改这个函数的入参/返回值有风险（它可能同时服务于图标角标路径，
//   改错会让图标角标也挂掉）。宁可多跑一轮，不可再翻车。
static void rep_SetExistingBadge(id self, SEL _cmd, id appID, unsigned long long count) {
    g_lastExistingCount = count;
    g_lastExistingApp = is_string(appID) ? appID : nil;
    if (count > 0) {
        CBFLog(@"[?] SetExistingBadge app=%@ count=%llu  ← 探针：确认签名与调用时机",
               appID, count);
    }
    if (orig_SetExistingBadge) orig_SetExistingBadge(self, _cmd, appID, count);
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
    //   v0.8.3 实机日志已证实这条路径**确实被调用**（20+ 次），
    //   所以我上一轮「写路径不走这里」的推断是错的 —— 当时只是没打日志。
    CBFLog(@"[写] SetContainerCount app=%@ cid=%@ count=%llu", appID, containerID, count);

    if (count > 0) {
        // ⚠️ v0.9.1 修语义混用：这里传的是**单容器**计数，
        //   必须用 "C" 通道记账，不能与 rep_PrivSetBadge 的「app 总数」混在一张表。
        //   v0.9.0 两者共用 g_lastCount[appID] → 日志里
        //   `v=5`（总数）紧跟 `count=2`（单容器）被误判成「5→2 巨幅下降」→ 误 purge。
        //   注意：C 通道**只记账不触发 purge**，因为「单个容器计数变化」
        //   与「用户已读」没有必然关系，据此 purge 会误伤。
        unsigned long long delta = 0;
        note_count_change(appID, count, @"C", &delta);
    }

    if (orig_SetContainerCount) orig_SetContainerCount(appID, containerID, count);
}

static void rep_PrivSetBadge(id self, SEL _cmd, id badgeNumberObj, id bundleID, id completion) {
    long long v = -1;
    if (badgeNumberObj && [badgeNumberObj respondsToSelector:@selector(longLongValue)])
        v = [badgeNumberObj longLongValue];

    if (v == 0) {
        NSUInteger before = 0;
        pthread_mutex_lock(&g_lock);
        before = [g_containers[bundleID] count];
        pthread_mutex_unlock(&g_lock);
        purge_containers(bundleID);
        CBFLog(@"★ 清零信号 v=0 app=%@ 已知容器=%lu", bundleID, (unsigned long)before);
        mark_cleared(bundleID, YES);
    } else if (v > 0) {
        // ★★ v0.9.0 引入、v0.9.1 收紧：「未读数下降」= 用户已读。
        //   微信清角标**从不发 v=0**（v0.8.3 实机铁证，20 次上报最低只到 1），
        //   但它的未读总数会下降（4→3、5→2）—— 那才是真实的已读信号。
        //
        //   时机选在这里最好：_privSetBadgeNumberHook 是「系统准备设置角标」的入口，
        //   在 Crane 写入新值之前先把它的 per-container 缓存清掉，
        //   既不吞掉本次新消息（写入仍原样透传），又能让后续菜单读取拿到 0。
        //
        // ⚠️ v0.9.1 用 "A"（app 总数）通道记账，与单容器通道严格隔离。
        unsigned long long delta = 0;
        BOOL dropped = note_count_change(bundleID, (unsigned long long)v, @"A", &delta);
        if (dropped) {
            NSUInteger before = 0;
            pthread_mutex_lock(&g_lock);
            before = [g_containers[bundleID] count];
            pthread_mutex_unlock(&g_lock);

            // ★★ v0.9.1 修一个会误伤的连带缺陷：
            //   v0.9.0 在这里调 purge_containers(bundleID)，
            //   它会把该 app 的**所有**容器清零 —— 包括那些此刻
            //   仍有未读、用户还没看的容器。
            //   用户读掉 A 会话的同时，B 会话的未读就被一起清掉（吞消息）。
            //   现在精确到「当前 count 不高于 harvest 基线」的容器，
            //   即只清那些**确实是旧残留**的，有活跃未读的一律保留。
            unsigned long long purged = purge_app_residuals(bundleID);
            CBFLog(@"★ 未读下降即已读 v=%lld→清理残留 %llu 个 app=%@ 已知容器=%lu delta=%llu",
                   v, purged, bundleID, (unsigned long)before, delta);
            mark_cleared(bundleID, YES);
        } else {
            // 未读数没下降（新消息或未变），恢复正常计数
            mark_cleared(bundleID, NO);
        }
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
    // ★ v0.9.0：新增探针（只日志不改行为）。这个符号不在 LC_DYLD_EXPORTS_TRIE，
    //   dlsym 会失败并自动回退到 slide+vmaddr 地址下钩（hook_addr 内部已实现）。
    hook_addr((void **)&orig_SetExistingBadge, o->setExisting, "_setExistingBadgeCountForApplication", (void *)rep_SetExistingBadge);

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
        // ⚠️ 版本行**必须只用 ASCII**。含中文的 NSString 在 arm64e 上按 UTF-16
        //   存储，ASCII 字节会被 \0 隔开，产物里搜不到版本串 ——
        //   结果用户发日志过来时无法确认装的是哪一版，排查极痛苦。
        //   v0.9.0 就踩过这个坑（产物里搜不到 v0.9.0），本版起改为纯 ASCII 版本行，
        //   中文说明另起一行打。
        CBFLog(@"==== CraneBadgeFix BUILD_TAG_091 (2026-10-18) ====");
        CBFLog(@"版本 v0.9.1：plist 基线判据修 v0.9.0 回归（图标角标收消息不亮）+ 未读下降清残留");
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

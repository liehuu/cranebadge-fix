/*
 * CraneBadgeFix v0.9.5（清除已读残留容器：修快捷菜单挂数 + 新消息角标基数错）
 * ==============================
 * 修复 Crane 1.3.17 多开应用（微信等）「消息已读后，图标角标已消失、
 * 但快捷菜单（Haptic Touch）仍残留 per-container 未读数」。
 *
 * ════════════════════════════════════════════════════════════════════
 * ★★★ v0.9.5：用户实测反馈「快捷菜单挂 2，收到新消息角标变 3」
 * ════════════════════════════════════════════════════════════════════
 * 用户原话（01:59）：微信已读空后**不是角标挂 2，是快捷菜单挂 2，
 * 角标确实是空的**；此时再收到 1 条，**图标角标变成 3**，实际只有 1 条未读。
 *
 * ── 根因（(18).log 01:48:43~01:52:04 铁证）─────────────────────────
 * 微信在 UUID / DEFAULT 两个容器间来回记账，切换时旧容器不归零：
 *   01:51:36  v=4 → [写] DEFAULT=4   GetAppCount=6（DEFAULT 4 + UUID 2）
 *   01:52:03  v=1 → [写] UUID=1      GetAppCount=5（DEFAULT 4 + UUID 1）
 *   01:52:04  v=2 → [写] UUID=2      GetAppCount=6（DEFAULT 4 + UUID 2）
 * 用户已读（微信多开场景**从不发 v=0**，9 轮日志实证）后：
 *   · 快捷菜单读 per-container（GetContainerCount）→ 直接显示僵留容器的 2；
 *   · 图标角标此时恰好是空的（v 通道/回写把它压平），但**残留容器还在**；
 *   · 新消息到来时角标走 GetAppCount 求和 = 残留 2 + 新消息 1 = 3。
 * 即：**残留容器既污染快捷菜单（直接显示），又污染角标（新消息时参与求和）**。
 *
 * ── 修法 ───────────────────────────────────────────────────────────
 * 新消息 v 上报时（privSetBadge v>0，微信主动上报 = 确定信号），
 * 清除所有「非活跃容器」——最后一次写入早于本次 v 上报的容器。
 * 判据依据（9 轮日志铁证）：每次 v 上报后 1ms 内微信必把当前值写进
 * 活跃容器，因此 writeAt ≥ lastVAt 的才是活容器；旧容器是僵留残留。
 * purge 走 orig_SetContainerCount 直调（Crane 自己负责持久化，
 * 重启后也不复活），且不经过 rep_SetContainerCount，不会误标 writeAt。
 *
 * ⚠️ 安全阀：只对确认过「v 上报后紧跟容器写」配对模式的 app 启用
 *   （g_vWritePaired，微信 9 轮日志铁证）。未确认配对的 app 一概不动，
 *   避免误清「只走 v 通道、容器里是别处数据」的 app。
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
 *     有新消息的一律放过（zero_mode_should_suppress / app_safe_to_suppress）。
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
 * ── v0.9.2：作废「未读下降=已读」错误判据（v0.9.0/v0.9.1 的核心错误）─────
 * v0.9.1 实机日志铁证（00:05:11~00:05:16，同一模式连续出现 5 次）：
 *   00:05:11.828 ↓ 未读下降[A] app=com.tencent.xin 4 → 3
 *   00:05:11.832 [写] SetContainerCount count=3     ← 同一个值被写回
 *   00:05:13.449 ↓ 未读下降[A] app=com.tencent.xin 4 → 2
 *   00:05:13.454 [写] SetContainerCount count=2     ← 又是同一个值
 * → A 通道的 v 与 Crane 写入 per-container 的 count 是**同一份数据**，
 *   「下降」只是 Crane 内部重算的中间态，**不是**「用户已读」。
 *   v0.9.0/v0.9.1 据此做 purge，5 次全部「清理残留 0 个」，判据完全无效。
 * → 方法论教训：看到信号「会下降」就断定它代表用户行为是过度解读；
 *   必须检查**该信号与下游写入是否严格配对**——配对就说明是同一份数据。
 * 同版还修掉：清零标记被同毫秒撤销（加 3 秒保持期）、harvest 吞新消息
 * （改为只在启动瞬间登记一次）、日志降噪。
 *
 * ── v0.9.3：依据 v0.9.2 实机日志（00:27~00:30）再修三个缺陷 ────────────
 * 缺陷一（00:27:34 铁证）：启动清零窗口误吞新消息
 *   00:27:05.699 启动清零：plist 历史残留 0 个（plist 不存在）
 *   00:27:34.221 抑制 app 角标 1（清零窗口内、全部为残留）  ← 新消息被吞
 *   00:27:34.807 抑制 app 角标 2                           ← 又被吞
 *   根因：app_has_live_unread 在该 app 无任何已登记容器时返回 NO，
 *   调用方据此判定「全部为残留」。**没有残留可清时，恰恰最不该压制。**
 *   修：改为 app_safe_to_suppress——「有已知容器且全部未超基线」才压。
 * 缺陷二（00:29:23 铁证）：DEFAULT 容器未被任何机制覆盖
 *   GetAppCount = 各容器求和（00:29:23.841 → 4 = DEFAULT 1 + UUID 3；
 *   00:29:24.727 → 5 = DEFAULT 2 + UUID 3）。DEFAULT 不被 Crane 持久化
 *   进 plist（00:29:51 重启后 harvest 只登记到 UUID，DEFAULT 的 2 条
 *   未读就此丢失），只有运行期 remember_container 知道它存在。
 *   修：app_safe_to_suppress 把运行期已知容器一并纳入——非登记容器
 *   在启动后却有数，只可能是新消息（启动时 Crane 内存=plist）。
 * 缺陷三（00:29:55.040 铁证）：setExisting 探针签名错误，整体移除
 *   [?] SetExistingBadge app=__NSCFString count=10761763936
 *   —— appID 不是 bundle id、count 明显是误读参数。无信息量的 hook
 *   只会误导后续排查。同帧的另一条证据反而更有价值：00:29:55.037
 *   读取被压成 0 之后，00:29:55.040 Crane 立刻调 setExistingBadge
 *   推送——**Crane 是用我们 hook 的 getter 取值再推给 SpringBoard 的**，
 *   压制 getter 就能让图标归零，该路径已由现有 hook 覆盖。
 * 另修：v0.9.2 降噪没降干净——rep_GetContainerCount 里 v0.8.3 遗留的
 *   无条件读日志与条件打印并存（值变化时打两遍），已删除。
 * 缺陷四（代码审查发现，v0.9.2 潜在回归，比前三个更严重）：
 *   v0.9.2 修「清零标记被同毫秒撤销」时，把 rep_SetContainerCount 里的
 *   mark_cleared(NO) **触发点**也一起删了，且没有安排替代路径 →
 *   一旦发生 v=0（用户全部已读），is_cleared 永远停在 YES，
 *   之后的新消息读取侧一律返回 0，**角标永远不亮**。
 *   v0.9.2 日志没抓到 v=0（用户没清空未读）所以没暴露；v0.9.1 日志
 *   （00:05:11.832 已清零标记）证明 v=0 确实会出现。
 *   修：触发点放在 rep_PrivSetBadge 的 v>0 分支（微信上报正值未读），
 *   由 3 秒保持期挡掉 v=0 后同毫秒/紧接着的撤销请求并到期补撤销；
 *   旧值回写发生在 orig_PrivSetBadge 内部、不经过本函数，天然不误触发。
 *   一直没有 v>0 时 is_cleared 持续保持 → 残留角标永不复活（核心目的）。
 *
 * ── v0.9.4：修「当前 < 基线」被判据盲区吞掉（v0.9.3 实机日志铁证）───────
 * v0.9.3 实机日志（01:00~01:02）证明 v0.9.3 的三个修复都生效
 * （启动窗口后新消息全部透传、DEFAULT 场景未复现、降噪生效、
 *  v=0 链路对提醒事项/SideStore 按设计工作），但抓到新缺陷：
 *   01:01:48.201 从 plist 发现残留 基线count=3
 *   01:02:12.229 非清零信号 v=1 → [写] count=1  ← 用户已读到剩 1 条（或新来 1 条）
 *   01:02:12.230 抑制残留容器角标 1              ← 当前 1 < 基线 3，被误当旧残留
 *   01:02:12.239 清零完成：已清 1 个残留         ← purge 还把真实计数清成了 0
 * 「当前 > 基线 ⇒ 新消息」只覆盖未读**增加**，不覆盖**减少到基线以下**——
 * 而「读完旧的再来新的」恰恰是最常见场景。
 * 修：zeroMode 窗口内任何一次**主动上报**（SetContainerCount 写回，实测
 * 每次都有 v 调用前置）都标记该容器为活跃（g_zeroLive），此后一律不压不清；
 * Crane 的 plist 周期回写与 purge 的 orig 直调都不经过本函数，不会误标。
 * 同版把 purge_harvested_only 的「清零完成」改为结果不变不打印
 * （01:01:57~01:02:18 连续 5 行相同内容是纯噪声）。
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
 * 同时新增 setExisting 探针（v0.9.3 已整体移除，签名实测错误，见 v0.9.3 节）：
 *   hook `_setExistingBadgeCountForApplication`@0x69f8，只打日志不改行为。
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
#import <sys/time.h>

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
    uintptr_t getCnt, setCnt, getApp, privSet;
} crane_offs_t;

// 1.3.17 symtab 实测偏移（arm64e / arm64 两分片）
// ⚠️ v0.9.3 移除 setExisting（0x69f8 / 0x6590）：探针实测签名错误，
//   详见文件头 v0.9.3 节与下方「已移除」说明块。
static const crane_offs_t kOffArm64e = { 0x6acc, 0x6f54, 0x6c4c, 0x7c5c };
static const crane_offs_t kOffArm64  = { 0x6734, 0x6b34, 0x689c, 0x7774 };

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

// ── ⛔ v0.9.3 已移除：_setExistingBadgeCountForApplication 探针 ──────────
//
// v0.9.0 加入（只日志不改行为），v0.9.2 实机日志证明**签名假设是错的**：
//   00:29:55.040 [?] SetExistingBadge app=__NSCFString count=10761763936
//   - appID 打出来是 __NSCFString（不是 bundle id）
//   - count=10761763936 明显是误读参数（指针/错位数据被当成整数）
// 无信息量的 hook 只会误导后续排查，整体移除（含 typedef / orig 指针 /
// g_lastExistingCount / g_lastExistingApp 死代码）。
//
// 同帧的另一条证据反而更有价值：00:29:55.037 读取被压成 0 之后，
// 00:29:55.040 Crane 立刻调 setExistingBadge 推送——说明 **Crane 是用
// 我们 hook 的 getter 取值再推给 SpringBoard 的**，压制 getter 就能让
// 图标归零，这条路径已由 GetContainerCount/GetAppCount 的 hook 覆盖。

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

// ★★ v0.9.5：容器写入时刻表 + app 最近一次 v 上报时刻 + v→写配对确认。
//   用途：识别「非活跃容器」（已读后无人更新的僵留容器），在新消息
//   v 上报时清除之（详见文件头 v0.9.5 节与 purge_stale_containers）。
static NSMutableDictionary *g_containerWriteAt = nil;   // appID -> {cid -> @(uptime)}
static NSMutableDictionary *g_lastVAt        = nil;     // appID -> @(uptime)
static NSMutableSet        *g_vWritePaired   = nil;     // 确认「v 上报后紧跟容器写」的 app
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

// ★★ v0.9.2：清零标记加**保持期**，防止被同一事件里的回写立刻抵消。
// ★★ v0.9.3：补上「保持期挡掉的撤销」的到期补撤销 + 明确撤销触发点。
//
// 实机日志铁证（v0.9.1，00:05:11.832，五次全部如此）：
//   00:05:11.832 已清零标记: com.tencent.xin      ← mark_cleared(YES)
//   00:05:11.832 撤销清零标记: com.tencent.xin    ← 同一毫秒被撤销！
//   00:05:11.832 [写] SetContainerCount count=3
//
// 成因：v=0 分支里我们先 mark_cleared(YES)，然后调 orig_PrivSetBadge；
// Crane 在其中把 count>0 回写进容器 → 触发 rep_SetContainerCount 的
// mark_cleared(NO) → 刚设上的标记被**同一毫秒**撤销 → 读取侧压制从未生效。
//
// v0.9.2 的解法：置位后进入「保持期」（CLEAR_HOLD_SECONDS），期内忽略撤销请求。
// ⚠️ 但 v0.9.2 同时把撤销的**触发点**（rep_SetContainerCount 里的 mark_cleared(NO)）
//    也一起删了，且没有安排任何替代路径 → 一旦发生 v=0（用户全部已读），
//    is_cleared 将**永远停在 YES**：之后来的新消息，读取侧一律返回 0，
//    角标永远不亮。v0.9.2 实机日志里没出现 v=0（用户没把未读清空），
//    所以这个潜在回归没有暴露——但 v0.9.1 日志证明 v=0 是会出现的。
//
// v0.9.3 的完整设计：
//    ① 撤销触发点 = rep_PrivSetBadge 的 **v>0 分支**（微信上报正值未读）。
//      ⚠️ 不能放在 rep_SetContainerCount：容器写回分「v=0 后同毫秒的 Crane
//      旧值回写」与「微信新未读上报」两种，从数值上无法区分，放那里会误撤销
//      → 残留复活。而 v>0 是微信**主动上报**的正值未读，才是确定信号；
//      且旧值回写发生在 orig_PrivSetBadge 内部，不经过 rep_PrivSetBadge，
//      天然不会误触发。
//    ② 保持期内忽略撤销请求（挡掉 v=0 后 1 秒内就到来的 v>0），但**到期后
//       补一次撤销**（见下方 dispatch_after）——否则「v=0 后立刻来新消息」
//       会被保持期吞掉且永不补显示。
//    ③ 保持期之外的 v>0 → 真正撤销 → 角标恢复显示。
//    ④ 没有任何 v>0 时（用户已读后一直没有新消息）→ is_cleared 一直保持，
//       残留角标永远不会复活——这正是本补丁的核心目的。
static NSMutableDictionary *g_clearedAt = nil;   // appID -> @(置位时的 uptime 秒)

#define CLEAR_HOLD_SECONDS 3.0

static double uptime_now(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

static void mark_cleared(id appID, BOOL cleared) {
    if (!is_string(appID)) return;
    pthread_mutex_lock(&g_lock);
    if (cleared) {
        if (![g_clearedApps containsObject:appID]) {
            [g_clearedApps addObject:appID];
            CBFLog(@"已清零标记: %@（保持期 %.1f 秒）", appID, CLEAR_HOLD_SECONDS);
        }
        g_clearedAt[appID] = @(uptime_now());
    } else {
        NSNumber *at = g_clearedAt[appID];
        if (at && (uptime_now() - at.doubleValue) < CLEAR_HOLD_SECONDS) {
            // ★ 保持期内：忽略撤销，避免被同一次事件的 Crane 回写抵消
            double remain = CLEAR_HOLD_SECONDS - (uptime_now() - at.doubleValue);
            CBFLog(@"保持期内忽略撤销: %@（剩余 %.1f 秒）", appID, remain);
            double stamp = at.doubleValue;
            pthread_mutex_unlock(&g_lock);
            // ★★ v0.9.3：被保持期挡掉的撤销不能就这么丢了。
            //   场景：v=0（全部已读）后 1 秒来了新消息 → 写回被保持期挡掉，
            //   若之后没有新的写回，角标会永远停在被压制的状态。
            //   到期后补一次撤销；补之前校验时间戳——若期间又来了新的 v=0
            //   （用户再次全部已读），时间戳已被刷新，此时不补刀，保持压制。
            NSString *appCopy = [appID copy];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remain * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                pthread_mutex_lock(&g_lock);
                NSNumber *nowAt = g_clearedAt[appCopy];
                BOOL stillMine = nowAt && (nowAt.doubleValue == stamp) &&
                                 [g_clearedApps containsObject:appCopy];
                pthread_mutex_unlock(&g_lock);
                if (stillMine) {
                    CBFLog(@"保持期到点补撤销: %@", appCopy);
                    mark_cleared(appCopy, NO);   // 保持期已过，必然真正撤销
                }
            });
            return;
        }
        if ([g_clearedApps containsObject:appID]) {
            [g_clearedApps removeObject:appID];
            CBFLog(@"撤销清零标记: %@", appID);
        }
        [g_clearedAt removeObjectForKey:appID];
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

// ★★ v0.9.5：记录容器「被写入」的时刻。只由 rep_SetContainerCount 调用
//   （读路径 remember_container 不记录——读取不是活跃证据）。
//   purge 的 orig 直调不经过本函数，因此「清理」不会被误判成「活跃写入」。
static void note_container_write(id appID, id containerID) {
    if (!is_string(appID) || !is_string(containerID)) return;
    pthread_mutex_lock(&g_lock);
    NSMutableDictionary *w = g_containerWriteAt[appID];
    if (!w) { w = [NSMutableDictionary dictionary]; g_containerWriteAt[appID] = w; }
    [w setObject:@(uptime_now()) forKey:containerID];
    pthread_mutex_unlock(&g_lock);
}

// ════════════════════════════════════════════════════════════════════
// ⛔ v0.9.2 已整体删除：「未读数下降」判据及其记账表
// ════════════════════════════════════════════════════════════════════
// v0.9.0 引入、v0.9.1 分通道加固，v0.9.2 **整体删除**。
//
// 删除理由是实机日志证明的**根本性错误**，不是调参问题：
//
// v0.9.1 实机日志（00:05:11~00:05:16，同一模式连续出现 5 次）：
//   00:05:11.828 ↓ 未读下降[A] app=com.tencent.xin 4 → 3
//   00:05:11.832 [写] SetContainerCount cid=2C76F901… count=3   ← 同一值回写
//   00:05:13.449 ↓ 未读下降[A] app=com.tencent.xin 4 → 2
//   00:05:13.454 [写] SetContainerCount cid=2C76F901… count=2   ← 同一值回写
//   00:05:14.453 ↓ 未读下降[A] app=com.tencent.xin 4 → 3
//   …… 五次全部如此，每次「下降」后 0.3 秒内 Crane 都把**完全相同的值**写回。
//
// → A 通道的 v 与 Crane 写入 per-container 的 count 是**同一份数据**，
//   「下降」只是 Crane 内部重算的中间态，**不是**「用户已读」。
// → 后果：v0.9.0/v0.9.1 的 purge 五次全部「清理残留 0 个」，判据完全无效；
//   且每次下降都会置 is_cleared(YES)，开启一条**错误的压制路径**。
//
// 现在只保留唯一确定性信号：v == 0（实测提醒事项 / SideStore / 抖音确实会发 v=0）。
// ⚠️ v0.9.3 修正表述（避免重蹈「过度解读」覆辙）：
//   微信**全部读完**时确实会发 v=0 —— v0.9.1 日志 00:05:11.832 的「已清零标记」
//   就是 v=0 分支置的位。v0.9.2 日志（00:27~00:30）里没出现 v=0，只是因为
//   那段日志用户没把未读清空（最少也剩 1~3 条）。v=0 链路（purge_containers +
//   3 秒保持期）**尚未在 v0.9.2 实机验证**，需要一次「把未读一条不剩读完」的测试。

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

// ★★ v0.9.5：清除「非活跃容器」的已读残留（用户实测「快捷菜单挂 2、
//   新消息角标变 3」的直接修复，根因分析见文件头 v0.9.5 节）。
//
// 判据：容器最后一次写入时刻（writeAt）早于该 app 最近一次 v 上报时刻
//   （lastVAt）⇒ 该容器在此次上报后没有更新 ⇒ 是僵留残留。
//   9 轮实机日志铁证：每次 privSetBadge 的 v 上报后 1ms 内，微信必把
//   当前值写进活跃容器（01:41:38.075 v=1 → 01:41:38.076 [写] count=1），
//   因此 writeAt ≥ lastVAt 的容器才是活的。
//
// 安全阀（两道）：
//   ① 只对确认过「v 上报后紧跟容器写」配对模式的 app 启用
//      （g_vWritePaired）——未确认的 app 容器里可能是别处数据，一概不动；
//   ② 只清 orig 当前值 > 0 的容器（0 无需清，少一次写入少一次竞争）。
//   purge 走 orig_SetContainerCount 直调：Crane 自己负责持久化（重启后
//   残留也不复活），且不经过 rep_SetContainerCount，不会误标 writeAt。
static void purge_stale_containers(id appID) {
    if (!is_string(appID)) return;
    if (!orig_SetContainerCount || !orig_GetContainerCount) return;

    pthread_mutex_lock(&g_lock);
    BOOL paired = [g_vWritePaired containsObject:appID];
    NSNumber *vAtNum = g_lastVAt[appID];
    double vAt = vAtNum ? vAtNum.doubleValue : 0.0;
    NSMutableSet *known = g_containers[appID];
    NSMutableDictionary *wats = g_containerWriteAt[appID];
    NSArray *cids = known.count ? [known allObjects] : nil;
    NSMutableArray *stale = [NSMutableArray array];
    if (paired && vAt > 0.0) {
        for (id cid in cids) {
            NSNumber *w = wats[cid];
            double wd = w ? w.doubleValue : 0.0;
            if (wd < vAt) [stale addObject:cid];
        }
    }
    pthread_mutex_unlock(&g_lock);

    for (id cid in stale) {
        unsigned long long cur = orig_GetContainerCount(appID, cid, 1);
        if (cur > 0) {
            CBFLog(@"v0.9.5 清除已读残留容器 app=%@ cid=%@（僵留值 %llu）", appID, cid, cur);
            purge_one(appID, cid);
        }
    }
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
    // ★ v0.9.2 降噪：plist 探测每 3 秒 × 4 条候选路径 = 30 秒刷 40 行，
    //   把真正的关键事件（写/读/清零）全埋了（实机日志 310 行里约 200 行是它）。
    //   改为只在「可读状态」或「文件大小」变化时打印，静态的 not-found 只打一次。
    static NSMutableDictionary *lastSeen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lastSeen = [NSMutableDictionary dictionary]; });

    NSString *sig = [NSString stringWithFormat:@"%d|%llu", exists ? 1 : 0, sz];
    pthread_mutex_lock(&g_lock);
    NSString *prevSig = lastSeen[p];
    [lastSeen setObject:sig forKey:p];
    pthread_mutex_unlock(&g_lock);

    if (!prevSig || ![prevSig isEqualToString:sig]) {
        CBFLog(@"BadgeStore 探测 %@ : exists=%d size=%llu bytes=%lu plist=%@",
               p, exists, sz, (unsigned long)raw.length,
               [obj isKindOfClass:[NSDictionary class]] ? @"dict" : (obj ? @"other" : @"nil"));
    }
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
static NSMutableSet        *g_zeroLive  = nil;   // v0.9.4：zeroMode 窗口内已活跃的 "appID|cid"
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
// ★ v0.9.4：g_zeroLive（活跃容器集合）也在此懒初始化。
static void harvest_init_once(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_harvested = [NSMutableDictionary dictionary];
        g_zeroLive  = [NSMutableSet set];
    });
}

// ★★ v0.9.4：「当前 > 基线」判据的盲区补丁 —— zeroMode 窗口内的活跃容器集合。
//
// 判据背景（v0.9.3 实机日志 01:02:12 铁证，完整分析见文件头 v0.9.4 节）：
//   01:01:48.201 从 plist 发现残留 基线count=3
//   01:02:12.229 非清零信号 v=1 → [写] count=1   ← 用户已读到剩 1 条（或新来 1 条）
//   01:02:12.230 抑制残留容器角标 1               ← 当前 1 < 基线 3，被误当旧残留吞掉
//   01:02:12.239 清零完成：已清 1 个残留          ← purge 还把真实计数清成了 0
// 「当前 > 基线 ⇒ 新消息」只覆盖未读**增加**，不覆盖**减少到基线以下**——
// 而「读完旧的再来新的」恰恰是最常见场景。
//
// 修正：窗口内任何一次**主动上报**（SetContainerCount 写回；实测每次都有
// privSetBadge 的 v 调用前置）都证明该容器变活了，与数值涨跌无关 → 标记
// live，此后一律不压、不清。
// ⚠️ Crane 对 plist 的周期性回写**不经过** SetContainerCount（v0.9.3 日志
//   里 plist 350/277 振荡时没有任何 [写] 行），purge 走 orig_SetContainerCount
//   直调同样不进本函数 —— 两者都不会误标。
static void zero_live_mark(id appID, id containerID) {
    if (!g_zeroMode) return;
    if (!is_string(appID) || !is_string(containerID)) return;
    long long baseline = 0;
    if (!residual_baseline(appID, containerID, &baseline)) return;   // 未登记：本来就不压不清
    harvest_init_once();
    NSString *pair = [NSString stringWithFormat:@"%@|%@", appID, containerID];
    pthread_mutex_lock(&g_harvestLock);
    BOOL already = [g_zeroLive containsObject:pair];
    if (!already) [g_zeroLive addObject:pair];
    pthread_mutex_unlock(&g_harvestLock);
    if (!already)
        CBFLog(@"zeroMode 标记活跃: %@|%@（窗口内出现主动上报，基线 %lld，此后不压不清）",
               appID, containerID, baseline);
}

static BOOL zero_live_contains(id appID, id containerID) {
    if (!is_string(appID) || !is_string(containerID)) return NO;
    harvest_init_once();
    NSString *pair = [NSString stringWithFormat:@"%@|%@", appID, containerID];
    pthread_mutex_lock(&g_harvestLock);
    BOOL r = [g_zeroLive containsObject:pair];
    pthread_mutex_unlock(&g_harvestLock);
    return r;
}

// ★★ v0.9.2：harvest 只在**启动那一瞬间**登记残留，不再每 3 秒重跑。
//
// v0.9.0/v0.9.1 的铁证缺陷（日志 00:05:07）：
//   00:05:07.515 [写] SetContainerCount count=1        ← 用户收到新消息
//   00:05:07.941 从 plist 发现残留 基线count=1          ← harvest 把它当残留登记
//   00:05:07.964 清零完成：已清 1 个残留                ← 于是这条新消息被清掉
// 因为 harvest 每 3 秒重跑，窗口内到达的新消息**第一次**被看到时
// 必然「基线 = 当前值」，随后的 purge 就把它当残留清掉 —— 图标角标闪一下就没。
//
// 修正：
//   ① harvest 只在 schedule_zero_mode 的第 0 轮跑一次（启动瞬间 = 真正的历史残留）；
//   ② 之后每 3 秒只重读 plist 做「基线比对」，**不再登记任何新残留**。
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

// ★★ v0.9.2：运行期轮询**只比对、不登记**。
//   用途：清零窗口内 Crane 若把某个容器写高了，我们能发现「新消息」并保护它，
//   但绝不能把它（连同首次出现的新容器）登记成残留 —— 那是 v0.9.1 吞新消息的根因。
static void poll_plist_for_live_unread(void) {
    NSMutableDictionary *cur = [NSMutableDictionary dictionary];
    snapshot_current_counts(cur);
    if (!cur.count) return;

    pthread_mutex_lock(&g_harvestLock);
    NSArray *pairs = [g_harvested allKeys];
    pthread_mutex_unlock(&g_harvestLock);
    if (!pairs.count) return;

    for (NSString *p in pairs) {
        long long baseline = 0;
        NSArray *kv = [p componentsSeparatedByString:@"|"];
        if (kv.count != 2) continue;
        if (!residual_baseline(kv[0], kv[1], &baseline)) continue;
        NSNumber *curNum = cur[p];
        long long curNow = curNum ? curNum.longLongValue : 0;
        if (curNow > baseline) {
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                CBFLog(@"运行期：新消息容器 %@|%@ 当前 %lld > 启动基线 %lld（不清零）",
                       kv[0], kv[1], curNow, baseline);
            });
        }
    }
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

        // ★ v0.9.4：窗口内出现过主动上报 ⇒ 已活跃，绝不清
        //   （v0.9.3 铁证 01:02:12：当前 1 < 基线 3 的已读/新消息被清成 0）
        if (zero_live_contains(kv[0], kv[1])) { skipped++; continue; }

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
    // ★ v0.9.4 降噪：结果与上一轮相同就不打印。
    //   v0.9.3 实机日志 01:01:57~01:02:18 连续 5 次「已清 1 个残留」其实
    //   什么都没变（plist 早已干净），纯噪声。
    static unsigned long long lastCleared = ~0ULL, lastSkipped = ~0ULL;
    if (cleared != lastCleared || skipped != lastSkipped) {
        CBFLog(@"清零完成：已清 %llu 个残留，保护 %llu 个有新消息的容器", cleared, skipped);
        lastCleared = cleared; lastSkipped = skipped;
    }
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

    // ★ v0.9.4：窗口内出现过主动上报 ⇒ 容器已活跃，无论数值涨跌都不压
    //   （v0.9.3 铁证 01:02:12：当前 1 < 基线 3 的已读/新消息被误当残留吞掉）
    if (zero_live_contains(appID, containerID)) return NO;

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

// ★★ v0.9.3：zeroMode 期间，rep_GetAppCount 是否可以整体压制该 app 的图标角标。
// 判据 = 该 app **至少有一个已知容器**，且全部已知容器都仍是「未超启动基线」的残留。
//
// ⚠️ v0.9.2 铁证缺陷（00:27:34，本版修）：
//   00:27:05.699 启动清零：plist 历史残留 0 个（plist 不存在）
//   00:27:34.221 [读] GetAppCount → 1
//   00:27:34.221 抑制 app 角标 1（清零窗口内、全部为残留）  ← 真实新消息被吞
//   00:27:34.807 抑制 app 角标 2                           ← 又被吞
//   根因：旧函数 app_has_live_unread 在该 app 没有任何已登记容器时返回 NO，
//   调用方 `!app_has_live_unread` 据此判定「全部为残留」→ 开压。
//   **没有残留可清的时候，恰恰最不该压制。**
//
// ⚠️ v0.9.3 同时覆盖 DEFAULT 容器（00:29:23 铁证）：
//   GetAppCount = 各容器求和（→ 4 = DEFAULT 1 + UUID 3；→ 5 = DEFAULT 2 + UUID 3）。
//   DEFAULT 不被 Crane 持久化进 plist（00:29:51 重启后 harvest 只登记到 UUID，
//   DEFAULT 的未读就此丢失），只有运行期 remember_container 知道它存在。
//   不纳入判据的后果：它的未读既不被压制也不被清零，图标角标永远带着它。
//
// 数据源 = 已登记残留（plist 基线比对）+ 运行期已知容器（g_containers）：
//   · 已登记容器：plist 当前值 > 基线 ⇒ 期间来了新消息 ⇒ 不压
//   · 非登记容器（如 DEFAULT）：启动时 plist 里没有它，启动后却有数
//     ⇒ 只可能是新消息（启动时 Crane 内存=plist）⇒ 不压
static BOOL app_safe_to_suppress(id appID) {
    if (!is_string(appID)) return NO;   // 非字符串 appID：无从判断，不压

    // ① 运行期已知容器（harvest 登记时会 remember_container，plist 残留也在此集合内）
    NSMutableSet *cids = [NSMutableSet set];
    pthread_mutex_lock(&g_lock);
    NSMutableSet *known = g_containers[appID];
    if (known.count) [cids unionSet:known];
    pthread_mutex_unlock(&g_lock);

    // ② 已登记残留的 pair（基线比对用）
    pthread_mutex_lock(&g_harvestLock);
    NSArray *pairs = [g_harvested allKeys];
    pthread_mutex_unlock(&g_harvestLock);
    NSString *prefix = [appID stringByAppendingString:@"|"];
    NSMutableArray *harvestedMine = [NSMutableArray array];
    for (NSString *p in pairs) if ([p hasPrefix:prefix]) [harvestedMine addObject:p];

    // 一个已知容器都没有 ⇒ plist 里也不会有残留（harvest 会 remember）⇒ 无可压对象
    if (!cids.count && !harvestedMine.count) return NO;

    // 一次重读 plist，供已登记容器做基线比对
    NSMutableDictionary *cur = [NSMutableDictionary dictionary];
    snapshot_current_counts(cur);

    for (NSString *p in harvestedMine) {
        NSArray *kv = [p componentsSeparatedByString:@"|"];
        if (kv.count != 2) continue;
        [cids removeObject:kv[1]];      // 已登记的走上方的基线比对，避免重复处理
        long long baseline = 0;
        if (!residual_baseline(kv[0], kv[1], &baseline)) continue;
        // ★ v0.9.4：窗口内已活跃的容器一律算「有新消息」，app 级不整体压制
        //   （与 zero_mode_should_suppress 的 live 检查保持一致）
        if (zero_live_contains(kv[0], kv[1])) {
            CBFLog(@"app_safe_to_suppress: %@ 容器 %@|%@ 窗口内已活跃 → 不压",
                   appID, kv[0], kv[1]);
            return NO;
        }
        NSNumber *curNum = cur[p];
        long long curNow = curNum ? curNum.longLongValue : 0;
        if (curNow > baseline) {
            CBFLog(@"app_safe_to_suppress: %@ 有新消息容器 %@|%@（%lld > 基线 %lld）→ 不压",
                   appID, kv[0], kv[1], curNow, baseline);
            return NO;
        }
    }

    // ③ 非登记容器：直调原函数取当前值（不经过我们的 hook，不持锁，无重入风险）
    for (NSString *cid in cids) {
        unsigned long long now = orig_GetContainerCount ? orig_GetContainerCount(appID, cid, 1) : 0;
        if (now > 0) {
            CBFLog(@"app_safe_to_suppress: %@ 有未登记容器 %@ 当前 %llu（启动时 plist 无此容器，视为新消息）→ 不压",
                   appID, cid, now);
            return NO;
        }
    }
    return YES;   // 全部已知容器都是未变残留 ⇒ 可以整体压制
}

static void schedule_zero_mode(void) {
    g_zeroMode = YES;
    CBFLog(@"进入启动清零模式 %d 秒", ZERO_MODE_SECONDS);

    // 第 0 轮：先把 plist 里的历史残留登记进 g_harvested
    harvest_from_plist();
    CBFLog(@"启动清零：plist 历史残留 %lu 个 (app,cid) 组合", harvest_count());

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    for (int i = 1; i < ZERO_MODE_SECONDS / 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 3.0 * NSEC_PER_SEC)), q, ^{
            if (!g_zeroMode) return;
            // ★ v0.9.2：不再 harvest（会吞新消息），只轮询比对，用于诊断。
            poll_plist_for_live_unread();
            purge_harvested_only();    // 只清「启动瞬间登记」的残留
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ZERO_MODE_SECONDS * NSEC_PER_SEC)), q, ^{
        purge_harvested_only();          // 收尾：最后再清一次启动时登记的残留
        g_zeroMode = NO;
        // ★ v0.9.4：清空活跃标记。窗口结束后 zero_mode_should_suppress /
        //   app_safe_to_suppress 都不再走 zeroMode 分支，留着无害，清掉更干净。
        pthread_mutex_lock(&g_harvestLock);
        [g_zeroLive removeAllObjects];
        pthread_mutex_unlock(&g_harvestLock);
        CBFLog(@"启动清零模式结束，已恢复正常计数");
    });
}

#pragma mark - C 函数替换

static unsigned long long rep_GetContainerCount(id appID, id containerID, unsigned long long flag) {
    unsigned long long cnt = orig_GetContainerCount ? orig_GetContainerCount(appID, containerID, flag) : 0;
    remember_container(appID, containerID);
    if (cnt > 0) {
        // ★ v0.9.2 降噪：快捷菜单每 7~15 秒轮询一次且值不变，
        //   会持续刷屏（实机日志末尾 5 行全是值=4 的重复读取）。
        //   改为只在「该容器的读数发生变化」时打印。
        if (is_string(appID) && is_string(containerID)) {
            static NSMutableDictionary *lastRead = nil;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ lastRead = [NSMutableDictionary dictionary]; });
            NSString *k = [NSString stringWithFormat:@"%@|%@", appID, containerID];
            NSString *v = [NSString stringWithFormat:@"%llu", cnt];
            pthread_mutex_lock(&g_lock);
            NSString *pv = lastRead[k];
            [lastRead setObject:v forKey:k];
            pthread_mutex_unlock(&g_lock);
            // ⚠️ 值未变时只**跳打印**，绝不能 return ——
            //   提前 return 会跳过下面的压制逻辑（zeroMode / is_cleared），
            //   导致清零失效。这是 v0.9.2 降噪改动里我自己引入的 bug，已修正。
            if (!pv || ![pv isEqualToString:v])
                CBFLog(@"[读] GetContainerCount app=%@ cid=%@ → %llu", appID, containerID, cnt);
        }
        // ⚠️ v0.9.3：此处原本还有一条 v0.8.3 遗留的**无条件**读日志，与上面的
        //   条件打印并存，导致值变化时同一行打两遍（00:27:34.221 连续两行 → 1），
        //   降噪等于没做。已删除。
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
    // ⚠️ setObject:forKey: 传 nil key 会抛异常。appID 理论上可能为 nil，
    //   日志里 GetContainerCount 的 appID 一直是合法 bundle id，但不做防护等于赌。
    if (!is_string(appID)) return cnt;
    {   // ★ v0.9.2 降噪：只在值变化时打印
        static NSMutableDictionary *lastApp = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ lastApp = [NSMutableDictionary dictionary]; });
        NSString *v = [NSString stringWithFormat:@"%llu", cnt];
        pthread_mutex_lock(&g_lock);
        NSString *pv = lastApp[appID];
        [lastApp setObject:v forKey:appID];
        pthread_mutex_unlock(&g_lock);
        if (!pv || ![pv isEqualToString:v])
            CBFLog(@"[读] GetAppCount app=%@ → %llu", appID, cnt);
    }

    // ★ v0.9.1：zeroMode 期间，只有当该 app **有已知容器且全部无新消息**时才压制。
    //   · 一个已知容器都没有 ⇒ 没有残留可清（harvest 会 remember，plist 有残留就一定有）
    //     ⇒ 不压。v0.9.2 在这里误吞过新消息（00:27:34 铁证，见 app_safe_to_suppress）。
    //   · 任一新消息容器（含 DEFAULT 这类未登记容器）⇒ 不压，避免吞掉图标角标。
    if (g_zeroMode && app_safe_to_suppress(appID)) {
        CBFLog(@"抑制 app 角标 %llu app=%@（清零窗口内、全部为残留）", cnt, appID);
        return 0;
    }
    if (is_cleared(appID)) {
        CBFLog(@"抑制 app 角标 %llu app=%@（已读标记）", cnt, appID);
        return 0;
    }
    return cnt;
}

static void rep_SetContainerCount(id appID, id containerID, unsigned long long count) {
    remember_container(appID, containerID);
    // ★★ v0.9.5：记录写入时刻（purge_stale_containers 的判据来源），
    //   并做「v 上报后紧跟容器写」的配对确认——2 秒内发生过 v 上报
    //   即视为配对（实测间隔约 1ms，2 秒窗口极其宽松）。
    note_container_write(appID, containerID);
    if (is_string(appID)) {
        pthread_mutex_lock(&g_lock);
        NSNumber *vAt = g_lastVAt[appID];
        if (vAt && (uptime_now() - vAt.doubleValue) < 2.0)
            [g_vWritePaired addObject:appID];
        pthread_mutex_unlock(&g_lock);
    }
    // ★★ v0.9.4：zeroMode 窗口内的每一次主动写回都标记该容器为「活跃」。
    //   这是「当前 > 基线」判据的盲区补丁：用户已读到剩 1 条（当前 1 < 基线 3）
    //   或新来 1 条，旧判据都会误当成残留 → 抑制 + purge 清掉（v0.9.3 铁证 01:02:12）。
    //   窗口内的主动上报与数值涨跌无关，一律证明容器变活。
    //   Crane 的 plist 周期回写与 purge 的 orig 直调都不经过本函数，不会误标。
    zero_live_mark(appID, containerID);

    // ⚠️ v0.9.3 注意：本函数**不**做清零标记撤销（曾在此处放触发点，已移除）。
    //   原因：容器写回分两种，从数值上无法区分——
    //     ① v=0 后同毫秒，Crane 把自己内存里的旧值刷回来（v0.9.1 铁证：
    //        已清零标记 → 同毫秒 [写] count=3）。这是**旧值回写**，
    //        撤销它 = 残留复活（用户最初报的 bug）。
    //     ② 微信新的未读上报（每次 [写] 前面都有一次 privSetBadge 的 v 调用）。
    //    ①由 3 秒保持期挡掉；②的撤销触发点改放在 rep_PrivSetBadge 的
    //    v>0 分支——v>0 是微信主动上报的正值未读，才是「新消息」的确定信号。
    //   （v0.9.2 曾把撤销触发点整体删掉且无替代 → v=0 后 is_cleared 永远
    //    停在 YES、新消息角标永远不亮，是更严重的潜在回归。）

    // ★ v0.8.3 诊断：这是 Crane 写入 per-container 角标缓存的唯一入口（实测 20+ 次）。
    CBFLog(@"[写] SetContainerCount app=%@ cid=%@ count=%llu", appID, containerID, count);

    if (orig_SetContainerCount) orig_SetContainerCount(appID, containerID, count);
}

static void rep_PrivSetBadge(id self, SEL _cmd, id badgeNumberObj, id bundleID, id completion) {
    long long v = -1;
    if (badgeNumberObj && [badgeNumberObj respondsToSelector:@selector(longLongValue)])
        v = [badgeNumberObj longLongValue];

    // ★★ v0.9.5：记录最近一次 v 上报时刻（v=0 与 v>0 都是确定信号）。
    //   purge_stale_containers 用它区分「活跃容器」与「僵留残留」。
    if (is_string(bundleID) && v >= 0) {
        pthread_mutex_lock(&g_lock);
        g_lastVAt[bundleID] = @(uptime_now());
        pthread_mutex_unlock(&g_lock);
    }

    if (v == 0) {
        NSUInteger before = 0;
        pthread_mutex_lock(&g_lock);
        before = [g_containers[bundleID] count];
        pthread_mutex_unlock(&g_lock);
        purge_containers(bundleID);
        CBFLog(@"★★ 清零信号 v=0 app=%@ 已知容器=%lu → 已清 Crane 缓存并抑制读取", bundleID, (unsigned long)before);
        mark_cleared(bundleID, YES);
    } else if (v > 0) {
        // ★★ v0.9.3：v>0 是「微信上报了正值未读」——**新消息的确定信号**，
        //   也是清零标记的撤销触发点（v0.9.2 漏掉的就是这个，见 mark_cleared 注释）。
        //   · 与 3 秒保持期配合：v=0 后同毫秒的 Crane 旧值回写是**容器写回**、
        //     不经过本函数，天然不会误触发；v=0 后紧接着的 v>0（保持期内）
        //     会被 mark_cleared 忽略并安排到期补撤销。
        //   · 未设置过 is_cleared 的 app（含提醒事项/SideStore/抖音等其他 app）
        //     这里是纯 no-op，不影响任何现有行为。
        if (is_cleared(bundleID)) mark_cleared(bundleID, NO);
        // ═══ ★★ v0.9.2：作废「未读下降 = 已读」判据（v0.9.0/v0.9.1 的核心错误）═══
        //
        // 实机日志铁证（v0.9.1，00:05:11~00:05:16，五次全部如此）：
        //   00:05:11.828 ↓ 未读下降[A] app=com.tencent.xin 4 → 3
        //   00:05:11.832 [写] SetContainerCount count=3     ← 同一个值被写回
        //   00:05:13.449 ↓ 未读下降[A] app=com.tencent.xin 4 → 2
        //   00:05:13.454 [写] SetContainerCount count=2     ← 又是同一个值
        //   ……5 次下降，每次都在 0.3 秒内被 Crane 写回**完全相同的值**。
        //
        // 结论：A 通道的 v 与 Crane 写入 per-container 的 count 是**同一份数据**，
        //「下降」只是 Crane 内部重算时的中间态，**不是**「用户已读」的信号。
        // v0.9.0/v0.9.1 基于它做 purge，5 次全部「清理残留 0 个」—— 判据完全无效。
        //
        // 现在的处理：v > 0 一律**如实透传**，不做任何 purge。
        // 已读清零只认 v == 0 这一个确定性信号（其他 app 的提醒事项/SideStore
        // 实测确实会发 v=0）。⚠️ v0.9.3 修正：微信并非「从不发 0」——
        // v0.9.1 日志里 v=0 出现过（00:05:11.832 已清零标记）；v0.9.2 日志没抓到
        // 只是因为用户没把未读清空。v=0 链路尚待一次「全部读完」的实机验证。
        //
        // ⚠️ v0.9.3 更正上面那条旧警告：v>0 时**可以**在这里 mark_cleared(NO)，
        //   前提是 mark_cleared 内部有保持期。v0.9.1 的错误不是「在 v>0 撤销」，
        //   而是「撤销发生在保持期概念存在之前」——v==0 刚置位，紧接着 Crane 回写
        //   count>0 触发撤销，同一毫秒互相抵消，读取侧压制从未生效（日志五次
        //   「已清零标记」后面紧跟「撤销清零标记」）。
        //   现在由 mark_cleared 的**保持期**统一裁决：保持期内的撤销一律忽略
        //   （并安排到期补撤销），保持期之外的撤销才真正生效。
        CBFLog(@"非清零信号 v=%lld app=%@ → 如实透传", v, bundleID);
        // ★★ v0.9.5：清除非活跃容器的已读残留（用户实测「快捷菜单挂 2、
        //   新消息角标变 3」的直接修复）。时机选在 orig_PrivSetBadge 之前：
        //   微信随后 1ms 内写入新值覆盖，视觉上不会闪断；被清的容器即使
        //   马上要被复用，也会立刻被写成当前值。
        purge_stale_containers(bundleID);
    } else {
        CBFLog(@"异常信号 v=%lld app=%@（既非 0 也非正数，不做处理）", v, bundleID);
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
    // ⚠️ v0.9.3 移除 setExisting 探针：签名实测错误（app=__NSCFString、
    //   count=10761763936），无信息量。详见文件头 v0.9.3 节。

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
        CBFLog(@"==== CraneBadgeFix BUILD_TAG_095 (2026-10-19) ====");
        CBFLog(@"版本 v0.9.5：清除已读残留容器，修快捷菜单挂数 + 新消息角标基数错");
        resolve_substrate();
        if (!pMSHookFunction) { CBFLog(@"substrate 不可用，退出"); return; }

        g_clearedApps = [[NSMutableSet alloc] init];
        g_clearedAt   = [[NSMutableDictionary alloc] init];
        g_containers  = [[NSMutableDictionary alloc] init];
        // ★★ v0.9.5：见 purge_stale_containers 注释
        g_containerWriteAt = [[NSMutableDictionary alloc] init];
        g_lastVAt          = [[NSMutableDictionary alloc] init];
        g_vWritePaired     = [[NSMutableSet alloc] init];

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

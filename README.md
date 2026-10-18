# CraneBadgeFix

修复 Crane 1.3.17 多开应用（微信等）「消息已读后，图标角标已消失、但快捷菜单仍残留 per-container 未读数」的独立补丁 tweak。

## ⛔ 当前版本 v0.8（保守安全版）—— 请先读这一段

**v0.7 导致用户手机重启后死机、无法进入系统**（只能关闭插件注入才能开机）。
v0.8 已把 v0.7 引入的**全部高危代码删除**，只保留此前已在真机验证、从不崩溃的 C 函数层 hook。

### 死机根因（已确定）

```objc
Class owner = NSClassFromString(g_resetOwnerName);
((resetBadge_t)g_imp_reset)(owner, g_sel_reset, cid, appID);
```

`crane_resetBadgeOfContainerWithIdentifier:ofApplicationWithIdentifier:`
是**系统私有类的【实例】方法**，v0.7 却把 `Class` 对象本身当成 `self` 传了进去。
实例方法会去访问 `self` 的 ivar，而 `Class` 对象的内存布局与实例布局完全不同
→ **越界访问 → EXC_BAD_ACCESS → SpringBoard 启动即崩溃 → 开不了机**。

v0.6 之所以侥幸没崩，是因为它按镜像过滤、从未找到这个 API；v0.7 去掉过滤后开始找到，
于是每次 purge 崩一次。

### v0.8 做了什么

| 项目 | v0.7 | v0.8 |
|---|---|---|
| 调用 `crane_resetBadge...` | ⛔ 有（死机） | ✅ 已删除 |
| `class_replaceMethod` 改系统私有类方法表 | ⛔ 有 | ✅ 已删除 |
| `badgeValueForBundleID:` ObjC hook | ⛔ 有 | ✅ 已删除 |
| C 函数层 hook（4 个 MSHookFunction） | ✅ 有 | ✅ 保留（唯一已验证路径） |
| plist 递归深度上限 | ⛔ 无 | ✅ 8 层 |
| `g_harvested` 并发加锁 | ⛔ 无 | ✅ 有 |
| 直接重写 `BadgeStore.plist` | ⛔ 有 | ✅ 停用（见下） |

### ⚠️ 装之前请注意

- **如果设备上还装着 v0.7，请先关闭插件注入或卸载 `com.82flex.cranebadgefix`**，
  不要在未确认安全前反复重启。
- v0.8 是**保守版**：图标角标清零能力与 v0.6 相同（已验证有效），
  **快捷菜单的深层修复暂缓**。宁可少修，不可再崩。
- 安装后**不会自动重启 SpringBoard**（`postinst` 已移除 `killall`），需你手动重启一次。

### 为什么停用「直接重写 BadgeStore.plist」

v0.6/v0.7 曾每 3 秒把整个 plist 的 `NSNumber` 全压 0。静态审查发现两个问题：

1. **数据破坏**：递归压 0 不区分字段，若 plist 里还存了别的数值配置会被一并抹掉。
2. **竞争风险**：`atomically:YES` 重写整个文件，若此刻 Crane 正在读写同一 plist，
   会造成「Crane 内存缓存」与「磁盘内容」不一致。

v0.8 改为**一律通过 Crane 自己的 C 函数** `orig_SetContainerCount(app, cid, 0)` 清零——
由 Crane 自己负责持久化，内存与磁盘天然一致，且精确到单个容器。

## 📄 怎么看日志（v0.5 起）

日志**落盘到文件**，不用连电脑：

```
/var/mobile/Library/Crane/CraneBadgeFix.log      （RootHide 实测真实路径，优先）
/var/jb/var/mobile/Library/Crane/CraneBadgeFix.log
/tmp/CraneBadgeFix.log                            （前两者都失败时）
```

> 时间戳为**本地时区**（v0.6 起修复；v0.5 及更早用 `[NSDate date]`，恒为 UTC，
> 会看到 13:47 而手机是 21:47）。

查看方式（任选）：
- **手机端**：Filza /「文稿」App 打开上面路径直接看。
- **SSH**：`cat /var/mobile/Library/Crane/CraneBadgeFix.log`，或 `tail -f` 实时跟。
- **电脑端**：`Console.app` 或 `idevicesyslog` 过滤 `[CraneBadgeFix]`（NSLog 同步进 os_log）。

`postinst` 每次安装都会清空旧日志，所以装完重启后取到的就是这一次的完整日志。

日志里最关键的几行（v0.8）：
```
==== CraneBadgeFix v0.8 加载（保守安全版，仅 C 函数层 hook）====
找到 CraneSB: ...CraneSB.dylib  slide=0x...  arch=arm64e
已 hook(C) _badgeCountStoreGetContainerCount @0x...     ← C 层 hook 是否挂上
已 hook(C) _badgeCountStoreSetContainerCount @0x...
已 hook(C) _badgeCountStoreGetAppCount @0x...
已 hook(C) _privSetBadgeNumberHook @0x...
初始化完成（仅 C 函数层 hook）。日志路径 ...
BadgeStore 探测 ... : exists=1 size=... plist=dict    ← plist 是否读到
从 plist 发现残留: app=... cid=... count=...           ← 扫到的历史残留
_privSetBadgeNumberHook 被调用 badgeNumber=0 app=...  ← 微信清角标信号
```

## ⚠️ v0.3 失效复盘（重要，避免重蹈）

v0.3 用 `dlsym(CraneSB, "_badgeCountStoreGetContainerCount")` 这类按名解析。
实测装到手机上**完全没效果**——原因不是逻辑错，是**符号取不到**：

解析 CraneSB.dylib 的 `LC_DYLD_EXPORTS_TRIE` 后确认，下列符号**全都不在导出表里**：

```
_privSetBadgeNumberHook                                   ✗ 不在 export trie
_badgeCountStoreGetContainerCount                         ✗ 不在
_badgeCountStoreSetContainerCount                         ✗ 不在
_setExistingBadgeCountForApplication                      ✗ 不在
_queue_saveNotificationRecordHook                         ✓ 在（对照组）
```

它们虽然出现在 symtab（`N_SECT | N_EXT`），但 dyld 只把 export trie 里的符号暴露给
`dlsym` → `dlsym` 全部返回 NULL → **三个 hook 一个都没挂上**。

> 教训：交付验证不能只检查「我的 dylib 里有没有编进这个符号名」（那只是 dlsym 的
> **参数**），必须校验**目标 dylib 是否导出该符号**。v0.3 的验证链就断在这里。

## 原理（CraneSB.dylib 1.3.17 反汇编实证）

CraneSB 里角标有**两条独立的数据路径**：

| 显示位置 | 读取函数 | 语义 |
| --- | --- | --- |
| 图标角标 | `_badgeCountStoreGetAppCount(appID, 1)` | 遍历容器**求和**（app 级汇总） |
| 快捷菜单 | `_badgeCountStoreGetContainerCount(appID, containerID, 1)` | **每个容器单独显示** |

快捷菜单的调用点确认在 `_crane_replacementMenu` @ `0xf798`：

```
0xfb74: bl  _showContainerNotificationBadgesEnabled
0xfb78: cbz w0, ...                 ; 开关未开则不显示
0xfb7c: mov x0, x28                 ; appID
0xfb80: mov x1, x23                 ; containerID
0xfb84: mov w2, #1
0xfb88: bl  _badgeCountStoreGetContainerCount
0xfb8c: cmp w0, #1
0xfb90: b.lt ...                    ; < 1 则不画角标
```

### 为什么 v0.2 修不掉快捷菜单

微信清角标走 `-setBadgeNumber:forBundleIdentifier:withCompletionHandler:`，
被 Crane 的 `_privSetBadgeNumberHook` @ `0x7c5c` 拦截。它内部有分支：

- 拿到 containerID → 调 `_badgeCountStoreSetContainerCount(appID, containerID, n)` 更新容器缓存
- **拿不到 containerID（或前置判断不成立）→ 走 `0x7db0`「直接透传」分支**，
  用原始 badgeNumber 直接调 orig

第二种情况里，**系统角标被置 0（所以图标角标消失了），但 Crane 的 per-container
缓存完全没被动过** → 快捷菜单继续显示历史值。v0.2 只 hook 了
`SetContainerCount`，在这个分支下压根不会被触发，所以治不了快捷菜单。

### v0.4 策略：slide + vmaddr 直接对地址下钩

既然 `dlsym` 不可用，就改用**运行时地址**定位：

- CraneSB 两个分片的 `__TEXT vmaddr` 都是 `0x0`，symtab 里的 `n_value` 即 vmaddr
- 故 **运行时地址 = slide + vmaddr**
- `slide` ← `_dyld_get_image_vmaddr_slide(index)`
- 分片选择：`mh->cpusubtype == 0x80000002`（`CPU_SUBTYPE_ARM64E`）→ arm64e 表，否则 arm64 表

| 函数 | arm64e 偏移 | arm64 偏移 |
| --- | --- | --- |
| `_badgeCountStoreGetContainerCount` | `0x6acc` | `0x6734` |
| `_badgeCountStoreSetContainerCount` | `0x6f54` | `0x6b34` |
| `_badgeCountStoreGetAppCount` | `0x6c4c` | `0x689c` |
| `_setExistingBadgeCountForApplication` | `0x69f8` | `0x6590` |
| `_privSetBadgeNumberHook` | `0x7c5c` | `0x7774` |

hook 逻辑：

1. `_privSetBadgeNumberHook` —— 捕获「角标被设为 0」信号（微信清角标入口）。
   取值后先 `purge_containers()` 真正把该 app 所有已知容器计数经 orig 写 0
   （**这一步才让 BadgeStore.plist 真正干净**，是持久化的关键），
   再打清零标记兜底未记录到的容器。
2. `_badgeCountStoreGetContainerCount` —— per-container 读取出口（快捷菜单 + GetAppCount 求和）。
   已清零 app 或清零模式下返回 0。
3. `_badgeCountStoreGetAppCount` —— app 级读取出口（图标角标），同样归零。
4. `_badgeCountStoreSetContainerCount` —— 写入出口。`count > 0` 时撤销清零标记（新消息恢复显示）；
   `count == 0` 时打清零标记并把 app 级也写 0。

每个 hook 打完都会检查 `orig != NULL` 并打日志；若地址下钩失败（`orig` 仍为 NULL）
自动退回 `dlsym`，两条路都失败会打印 `*** 目标函数无法定位 ***` 明确报警。

### 启动清零模式：让清零结果持久化

用户实测反馈：「重启 springboard 后，角标的红点又回来」。原因是 v0.3 的 `postinst`
删了 `BadgeStore.plist` 却没重启 SpringBoard，运行中的 Crane 在退出时把内存里的旧计数
又写回了 plist。

v0.4 的处理：

- `postinst` **删掉 `killall -9 SpringBoard`**（这就是「安装完手机就自动重启」的来源），
  只保留删 plist。
- 补丁加载后进入 **12 秒启动清零模式**：期间
  - 每 2 秒把 `BadgeStore.plist` 里所有数字递归清零并原子写回；
  - `SetContainerCount` 收到的非零 count 一律压成 0（经 orig 回写，plist 随之干净）；
  - 读取出口一律返回 0。
- 12 秒后自动恢复正常计数显示，不影响之后的新消息。

> 因此：**装完补丁需要手动重启一次 SpringBoard（或关机重启）才会生效**——
> 这也是去掉自动 killall 之后的必然代价。Crane 的 per-container 角标被清理后，
> 之后不再复活。

补丁**不改 Crane 二进制**，独立 dylib 运行时解析 substrate 的 `MSHookFunction`。

> 注：这些导出 C 函数的第一个参数是 **appID**（bundle id），不是 `self`——
> 早期版本误当成 self，已在 v0.3 修正。

### 逆向方法论备忘（避免下次再踩）

CraneSB 的 **arm64 分片也使用 `LC_DYLD_CHAINED_FIXUPS`，`ptr_format = 6`
（`DYLD_CHAINED_PTR_64_OFFSET`）**，不是经典 rebase。所以：

- ObjC 元数据（classlist / class_ro_t / method_t / selrefs）里的指针**不是裸指针**，
  按 `BASE + vmaddr` 解析会全部失败（sel 反查为空、读出 `0x4000000001ce58` 之类怪值）。
- 试过 BASE = `0x100000000` / `0x1000000000000` / `0x10000000000000` 全部无效——
  方向性错误，问题不在基址而在编码格式。
- **可行绕行**：放弃解析 ObjC 结构，改从 symtab 反汇编**导出 C 函数**（地址明确，
  不需要解 chained fixup）。本补丁即走此路线。

## 构建

**不依赖 theos**，与抖音插件同款直编方案（`xcrun clang` + `codesign`），
零 SDK 下载、零 flakiness。GitHub Actions 一键构建，产物为 `out/*.deb`。

**架构 = 纯 arm64e（RootHide）**：注入目标 SpringBoard / runningboardd 是 A12+ 设备的
arm64e 系统进程，dyld 按 cpusubtype 精确匹配，纯 arm64 dylib 会静默拒绝加载。
control 的 `Architecture: iphoneos-arm64e` 与参考补丁 `cranepkdserverfix` 完全一致
（RootHide 版 Sileo 据此识别 roothide 生态、不再弹「Not Updated」）。

## 安装

1. 装 deb（脚本会删除坏缓存并重启 SpringBoard）
2. 确认注入进程：SpringBoard + runningboardd（与 CraneSB 本体一致）
3. 收新消息 → 读掉 → 观察图标角标**与**快捷菜单是否一起归零

## 符号表（CraneSB.dylib 1.3.17）

arm64e 分片（实际生效）：

| 符号 | 地址 | 签名 |
| --- | --- | --- |
| `_existingBadgeCountForApplication` | 0x6910 | `(id appID) -> NSUInteger` |
| `_setExistingBadgeCountForApplication` | 0x69f8 | `(id appID, NSUInteger count)` |
| `_badgeCountStoreGetContainerCount` | 0x6acc | `(id appID, id containerID, BOOL) -> NSUInteger` |
| `_badgeCountStoreGetAppCount` | 0x6c4c | `(id appID, BOOL) -> NSUInteger` |
| `_badgeCountStoreUpdateBadge` | 0x6e94 | `(id appID, BOOL)` |
| `_badgeCountStoreSetAppDict` | 0x6ee4 | `(id appID, id dict)` |
| `_badgeCountStoreSetContainerCount` | 0x6f54 | `(id appID, id containerID, NSUInteger count)` |
| `_badgeCountStore_init` | 0x7058 | `(void)` |
| `_privSetBadgeNumberHook` | 0x7c5c | `(id self, SEL, id badgeNum, id bundleID, id completion)` |

arm64 分片（仅作对照，设备上不加载）：0x6590 / 0x6674 / 0x6734 / 0x689c / 0x6a9c / 0x6b34 / 0x7774。

## 排错

- 装不上「Not Updated … for roothide」→ control 的 `Architecture` 必须是 `iphoneos-arm64e`
- `dpkg: missing final newline` → control 末行必须有换行（打包器已做 `rstrip + '\n'` 防御）
- 完全没效果 → 先看日志：`[CraneBadgeFix] v0.3 初始化完成 getContainer=1 setContainer=1 privSetBadge=1`，
  三个 hook 都应为 1；若 `privSetBadge=0` 说明 Crane 版本符号名有变

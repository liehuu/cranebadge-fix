# CraneBadgeFix

修复 Crane 1.3.17 多开应用（微信等）「消息已读后，图标角标已消失、但快捷菜单仍残留 per-container 未读数」的独立补丁 tweak。

## 原理（v0.3，CraneSB.dylib arm64e 反汇编实证）

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

### v0.3 策略

1. hook `_privSetBadgeNumberHook`：捕获「角标被设为 0」信号，把该 app 记入已清零集合
   （badgeNumber > 0 即新消息到达时自动取消标记，恢复正常显示）
2. hook `_badgeCountStoreGetContainerCount`：已标记的 app 一律返回 0。
   该出口**同时服务于快捷菜单读取与 GetAppCount 求和**，故两条路径一起归零
3. 保留 hook `_badgeCountStoreSetContainerCount` 作为第二清零信号来源（双保险）

补丁**不改 Crane 二进制**，独立 dylib 运行时解析 substrate 的 `MSHookFunction` 并按名 `dlsym`。

> 注：这些导出 C 函数的第一个参数是 **appID**（bundle id），不是 `self`——
> 早期版本误当成 self，已在 v0.3 修正。

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

# CraneBadgeFix

修复 Crane 1.3.17 多开应用（微信等）「消息已读、角标仍显示历史未读数」的独立补丁 tweak。

## 原理

Crane 的角标是「乐观合并」（只增不减），缓存落在 `/var/mobile/Library/Crane/BadgeStore.plist`。
微信清除角标走私有 `setBadgeNumber:0` 链路，未同步到 Crane 的 app 级汇总缓存，导致历史未读数被反复回写。

本补丁**不改 Crane 二进制**，独立 dylib 运行时解析 substrate 的 `MSHookFunction`，hook CraneSB.dylib 导出的 C 符号（真实签名已从 arm64 反汇编确认）：

- `_badgeCountStoreSetContainerCount(id self, id containerID, unsigned long long count)`
- `_badgeCountStoreUpdateBadge(id self, id appID)`
- `_setExistingBadgeCountForApplication(id self, unsigned long long count)`

拦截到「容器清零信号」（count == 0）时，强制同步把 app 级汇总缓存归零，抹掉赖着不走的「34」。

## 构建

**不依赖 theos**，与抖音插件同款直编方案（`xcrun clang` + `codesign`），
零 SDK 下载、零 flakiness。GitHub Actions 一键构建，产物为 `out/*.deb`。

## 安装

1. 装 deb（脚本会删除坏缓存并重启 SpringBoard）
2. 确认注入进程：SpringBoard + runningboardd（与 CraneSB 本体一致）
3. 观察角标是否随已读正确归零

## 符号表（CraneSB.dylib 1.3.17 arm64）

| 符号 | 地址 | 签名 |
| --- | --- | --- |
| `_existingBadgeCountForApplication` | 0x6590 | `(id, NSUInteger)` |
| `_setExistingBadgeCountForApplication` | 0x6674 | `(id, NSUInteger)` |
| `_badgeCountStoreGetContainerCount` | 0x6734 | `(id, id, id)` |
| `_badgeCountStoreGetAppCount` | 0x689c | `(id, id)` |
| `_badgeCountStoreUpdateBadge` | 0x6a9c | `(id, id)` |
| `_badgeCountStoreSetContainerCount` | 0x6b34 | `(id, id, NSUInteger)` |
| `_privSetBadgeNumberHook` | 0x7774 | `(id, id, ...)` |
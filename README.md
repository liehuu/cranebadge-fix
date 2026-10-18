# CraneBadgeFix

修复 Crane 1.3.17 多开应用（微信等）「消息已读、角标仍显示历史未读数」的独立补丁 tweak。

## 原理

Crane 的角标是「乐观合并」（只增不减），缓存落在 `/var/mobile/Library/Crane/BadgeStore.plist`。
微信清除角标走私有 `setBadgeNumber:0` 链路，未同步到 Crane 汇总缓存，导致历史未读数被反复回写。

本补丁**不改 Crane 二进制**，通过 hook CraneSB.dylib 导出的 C 符号：

- `_badgeCountStoreSetContainerCount` — 容器计数写入
- `_setExistingBadgeCountForApplication` — app 级汇总计数写入

拦截到「清零信号」（count == 0）时，强制同步把 app 级汇总缓存归零。

## 构建

用 theos 构建（rootless，Dopamine）：

```sh
# macOS / theos
make package
```

产物在 `packages/*.deb`。

## 安装

1. 装 deb
2. 脚本会删除坏缓存并重启 SpringBoard
3. 观察角标是否随已读正确归零

## 版本路线

- v0.1：v0.1 基于反汇编符号的 verify 版本，带 NSLog 诊断日志。装完后收一条新消息再读掉，观察红点是否消失。
- 若仍只增不减，再加 hook「app 级汇总写入」强制同步逻辑。
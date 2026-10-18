/*
 * CraneBadgeFix v0.2
 * ===================
 * 修复 Crane 1.3.17 多开应用（微信等）「消息已读后，图标/快捷菜单角标仍显示历史未读数」。
 *
 * 根因（CraneSB.dylib 1.3.17 arm64 反汇编）：
 *   角标 = 各容器未读之和，汇总缓存于 BadgeStore.plist。
 *   微信清角标走私有 setBadgeNumber:0 链路，未能把「容器清零」传导到
 *   Crane 的 app 级汇总缓存，历史值被反复回写。
 *
 * 本补丁不改 Crane 二进制，独立 dylib 运行时解析 substrate 的 MSHookFunction，
 * hook CraneSB 导出的 C 符号（真实签名已从反汇编确认）：
 *   _badgeCountStoreSetContainerCount(id self, id containerID, unsigned long long count)
 *   _badgeCountStoreUpdateBadge(id self, id appID)
 *   _setExistingBadgeCountForApplication(id self, unsigned long long count)
 *
 * 策略：
 *   透传 orig 后，检测到 count == 0 的容器清零信号时，额外调用
 *   _setExistingBadgeCountForApplication(self, 0) 把 app 级汇总强制归零，
 *   抹掉那份赖着不走的「34」。
 *
 * 编译：与抖音插件同款直编方案（详见 .github/workflows/build.yml），
 *       不依赖 theos / 不下载 SDK，零 flakiness。
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <string.h>

#pragma mark - substrate 运行时解析（同抖音 DouYinKeepPlay 方案）

typedef void (*MSHookFunction_t)(void *symbol, void *hook, void **old);
static MSHookFunction_t pMSHookFunction = NULL;

static void resolve_substrate(void) {
    void *h = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/ellekit.dylib", RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/substrate.dylib", RTLD_NOW);
    if (h) pMSHookFunction = (MSHookFunction_t)dlsym(h, "MSHookFunction");
    if (!pMSHookFunction) pMSHookFunction = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
}

#pragma mark - 定位 CraneSB 已加载镜像

// 遍历 dyld，找名字含 needle 的镜像完整路径（rootless 下带 /var/jb 前缀）
static char *find_image(const char *needle) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, needle)) return (char *)name;
    }
    return NULL;
}

#pragma mark - 真实函数签名（CraneSB 反汇编确认：对象参数均被 objc_retain）

typedef void (*setContainerCount_t)(id self, id containerID, unsigned long long count);
typedef void (*updateBadge_t)(id self, id appID);
typedef void (*setExistingBadge_t)(id self, unsigned long long count);

static setContainerCount_t orig_SetContainerCount = NULL;
static updateBadge_t      orig_UpdateBadge      = NULL;
static setExistingBadge_t real_SetExistingBadge = NULL;

static void rep_SetContainerCount(id self, id containerID, unsigned long long count) {
    // 1) 先透传 orig（Crane 内部走 count==0 的删除分支）
    if (orig_SetContainerCount) orig_SetContainerCount(self, containerID, count);

    // 2) 容器清零信号 -> 强制 app 级汇总也归零，抹掉历史缓存值
    if (count == 0 && self && real_SetExistingBadge) {
        real_SetExistingBadge(self, 0);
        NSLog(@"[CraneBadgeFix] container cleared -> force app aggregate = 0");
    }
}

static void rep_UpdateBadge(id self, id appID) {
    if (orig_UpdateBadge) orig_UpdateBadge(self, appID);
}

#pragma mark - 入口

__attribute__((constructor)) static void CBFInit(void) {
    @autoreleasepool {
        resolve_substrate();
        if (!pMSHookFunction) {
            NSLog(@"[CraneBadgeFix] substrate 不可用，退出");
            return;
        }

        char *crane = find_image("CraneSB");
        if (!crane) {
            NSLog(@"[CraneBadgeFix] 未找到 CraneSB 镜像，退出");
            return;
        }

        void *h = dlopen(crane, RTLD_NOW);
        if (!h) {
            NSLog(@"[CraneBadgeFix] dlopen CraneSB 失败: %s", crane);
            return;
        }

        void *setCnt = dlsym(h, "_badgeCountStoreSetContainerCount");
        void *updB   = dlsym(h, "_badgeCountStoreUpdateBadge");
        real_SetExistingBadge = (setExistingBadge_t)dlsym(h, "_setExistingBadgeCountForApplication");

        if (setCnt) pMSHookFunction(setCnt, (void *)rep_SetContainerCount, (void **)&orig_SetContainerCount);
        if (updB)   pMSHookFunction(updB,   (void *)rep_UpdateBadge,        (void **)&orig_UpdateBadge);

        NSLog(@"[CraneBadgeFix] 初始化完成 setContainer=%d updateBadge=%d setExisting=%d (CraneSB=%s)",
              setCnt != NULL, updB != NULL, real_SetExistingBadge != NULL, crane);
    }
}
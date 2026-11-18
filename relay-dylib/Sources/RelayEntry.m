//
//  RelayEntry.m
//  RelayDylib — 注入进官方 Minis 的中转站/路由器入口
//
//  为什么入口写在这里而不是 Swift：
//  Swift 不支持 `__attribute__((constructor))`，而 dylib 被 LC_LOAD_DYLIB
//  加载进来时没有任何人调用它 —— 必须靠 constructor 在进程里抢到第一跳。
//  所以这里只做一件事：进程加载时把控制权交给 Swift 那边。
//
//  ⚠️ 不要在 constructor 里直接碰 UIApplication / 窗口：这个时刻
//  UIApplicationMain 还没跑完，取窗口必然拿到 nil。RelayDylibMain 里
//  是延后 + 重试的，那层逻辑不要挪到这里来。
//

#import <Foundation/Foundation.h>

/// Swift 侧用 @_cdecl("RelayDylibMain") 导出，链接期为 C 符号。
extern void RelayDylibMain(void);

__attribute__((constructor))
static void RelayDylibCtor(void) {
    @autoreleasepool {
        RelayDylibMain();
    }
}

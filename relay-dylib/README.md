# Relay Dylib

注入进**官方 Minis** 的中转站 / 路由器入口。目标只有一个：上游发版时不用合并任何源码，
重新注入一次就能跟上。

## 交付物

**一个 `RelayDylib.dylib`**。手机上下载后用注入工具（TrollFools 之类）打进官方 Minis，
不用重新打包 ipa。CI 每次跑完都发到 release tag `relay`：

```
https://github.com/vipios/Ai-quanneng/releases/download/relay/RelayDylib.dylib
```

编不了 ipa 也没关系 —— 官方包自带 `NSAllowsArbitraryLoads` 与
`NSLocalNetworkUsageDescription`（来自上游基线），http 内网和本地网络权限都不需要额外改。
注入后打开悬浮球，自检页会直接显示这两项的实际值，是不是有都不用猜。

## 为什么不继续维护 fork

fork 的代价不在写功能，在每次上游更新都要解一遍冲突，而且冲突往往落在我们并不关心的
文件里（pbxproj、设置页、导航栏）。dylib 把这笔账换成：

- 官方源码零改动
- 我们的代码全在这一个目录里，跟上游没有交集
- 上游发版 → 重新注入 → 出包

## 目录

```
relay-dylib/
  Sources/
    RelayEntry.m         constructor：dylib 被加载时唯一的一跳（ObjC 才有）
    RelayMain.swift      悬浮球 + 找到窗口/顶层控制器 + present 面板
    RelayRootView.swift  v1 自检页（环境 / ATS / 内网连通性）
  build.sh               用 xcrun 直接编，不用 theos、不用 xcodeproj
```

配套脚本（仓库根 `scripts/`）：

- `inject_dylib.py` —— 给主二进制插 `LC_LOAD_DYLIB`（纯标准库，原地写 headerpad）
- `patch_infoplist.py` —— 补 ATS / 本地网络权限 / Bonjour 服务名

CI：`.github/workflows/relay-dylib.yml`。

## 三步链路

1. **加载**：`LC_LOAD_DYLIB` 指向 `@executable_path/Frameworks/RelayDylib.dylib`，
   dyld 在启动时加载 → `RelayEntry.m` 的 constructor 跑 → 调 `RelayDylibMain()`
2. **挂载**：等 `UIApplicationMain` 建好窗口（延后 + 有限次重试），往 key window 上
   放一个可拖动的悬浮球
3. **打开**：点球 → `present` 一个 `UIHostingController`，里面是 SwiftUI 页面

## 为什么入口是悬浮球

设置页是 SwiftUI 的 `List`，没有 `UITableViewDataSource` 可 hook；要往里插一行只能猜内部
层级，官方一改版就碎 —— 而那正是这套方案要避免的事。悬浮球只依赖 `UIWindow` 和
`UIViewController.present`，这两样不会变。

后面如果嫌它碍眼，可以换成长按手势或自建 URL scheme，都在 `RelayMain.swift` 一个文件里改。

## Info.plist 三项（缺了功能直接死）

| 键 | 为什么 |
|---|---|
| `NSAppTransportSecurity.NSAllowsArbitraryLoads` | 中转站/路由器都是 `http://192.168.x.x`，不放行会被 ATS 拦（-1022） |
| `NSLocalNetworkUsageDescription` | iOS 14+ 访问局域网要授权，缺了不弹框 |
| `NSBonjourServices += _minis-relay._tcp` | `RelayRoute` 靠 `NWBrowser` 主动触发授权弹窗 |

这三项是**进程级**的，dylib 运行时改不了，只能改 bundle 的 Info.plist 再重签。

## 版本计划

- **v1（当前）**：链路验证。悬浮球 + 自检页（能打开 = 注入成功；内网测试通过 = ATS 与权限都对）
- **v2**：搬 `RelayAdminView`（中转站后台）、`RelayRouterView`（路由器后台）。
  这两块几乎零耦合，只依赖 `RelayStore / RelayVault / RelayRoute`，可直接复制
- **v3**：添加 AI 中转站。唯一硬耦合点，计划用通用 JSON 合并写 `provider-config.json`，
  不强类型解析，官方换 schema 也不至于崩

## 本地怎么编

只有 macOS 能编（要 iPhoneOS SDK）：

```bash
./relay-dylib/build.sh
# 产物：relay-dylib/build/RelayDylib.dylib
```

注入单独跑：

```bash
python3 scripts/inject_dylib.py Payload/Minis.app/Minis \
  @executable_path/Frameworks/RelayDylib.dylib
python3 scripts/patch_infoplist.py Payload/Minis.app/Info.plist
codesign --force --sign - Payload/Minis.app/Frameworks/RelayDylib.dylib
codesign --force --sign - --entitlements ent.plist Payload/Minis.app
```

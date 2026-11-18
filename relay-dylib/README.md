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
    RelayBridge.m        v3：运行时找 App 的 @objc 配置写入通道，加一条服务商
    RelayMain.swift      悬浮球 + 独立浮层窗口 + 点球弹半屏面板 / 关面板 / 弹结果
    RelayRootView.swift  首页（三行入口，自检已移除）
    Relay/              从中转站 fork 原样搬来的页面（后台、路由器、Store/Vault/Route）
      RelayAddProviderView.swift       v3 表单：显示名 / 类型 / 地址 / Key（地址默认本地代理）
      RelayProviderInstaller.swift     v3 落点：拼 payload、翻 envelope
      RelayProxy.swift                 v4：本地 HTTP 代理，无感自动换线的核心
      RelayDrawer.swift                左滑抽屉：照 ipa 的 EdgeDrawer 交互，
                                      挂浮层窗口，任何界面左边缘右滑拉出
      RelayChatNavBar.swift            v5：聊天页顶部导航条（照 fork 1:1），
                                      盖在浮层顶部，左上角圆气泡开管理抽屉
      RelaySettingsDesign.swift        v5：设置页视觉参数（图标/字号/行高），
                                      照 fork 的 SettingsDesignTokens 搬来
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

## 线路怎么判（v3.1）

判定只有一个入口 `RelayProbe.resolve()`，两个页面共用同一份结果。

**什么时候重判**：进页面 / 切页面 / 回前台 / 下拉刷新 / **换网**。
换网靠常驻的 `NWPathMonitor` —— 它是 dylib 加载后立刻启动的（`RelayDylibMain`
里调 `RelayStore.bootstrap()`），不是等用户点开面板才算。所以你在聊天界面
把 WiFi 换成数据，判定已经在后台更新；下次点开面板看到的就是新结论。

**判什么**：

| 维度 | 依据 | 说明 |
|---|---|---|
| 走直连还是外网 | `http://<家里地址>:8080/health` 是否返回 `service: ai-relay` | 内网 0.07s vs 域名 2.5s，差 35 倍 |
| WiFi / 蜂窝 / 有线 | `NWPath.usesInterfaceType` | 接口类型，不需要任何 entitlement |
| 是不是别人家 WiFi | WiFi 下 /24 网段是否与家里地址一致（`getifaddrs` 读 en0） | 只判「网段相同」，不断言「在家」 |
| 8080 上是不是中转站 | `/health` 的 `service` 字段 | 网关之类占了端口会回 200，只看 200 会误判 |

结论文案（路由器页顶部 / 自检页）：

- `内网直连 · WiFi` —— 在家，走直连
- `外网 · 别人家 WiFi` —— WiFi 但网段不同，直连不通
- `外网 · 家里网段` —— 网段相同但中转站没响应（大概率 relay 挂了，不是走错地方）
- `外网 · 蜂窝数据` —— 数据网络
- `未联网` —— 断网，跳过探测（省 3.7 秒白等）

> SSID 读不到（TrollStore 装的包没有读 WiFi 名的 entitlement），所以「这是谁家
> 的 WiFi」永远只能靠可达性 + 网段反推，不靠名字。

## 版本计划

- **v1（已完成）**：链路验证。悬浮球 + 自检页（能打开 = 注入成功；内网测试通过 = ATS 与权限都对）
- **v2（已完成）**：搬 `RelayAdminView`（中转站后台）、`RelayRouterView`（路由器后台）。
  这两块几乎零耦合，只依赖 `RelayStore / RelayVault / RelayRoute`，可直接复制
- **v3（已完成）**：添加 AI 中转站。**不自己写 `provider-config.json`** ——
  v3 之后 SQLite（`provider-config.db`）才是权威，JSON 只是降级镜像，手写会被 DB
  dump 覆盖。改成在运行时找到 App 自己的 `@objc` 配置通道（`ConfigOffloadBridge`），
  用一条 `providers.add` 让 App 自己写完：ProviderInstance + Keychain 里的 Key +
  SQLite + JSON 镜像 + 按 `/v1/models` 拉模型 + 配置审计。
  代价是走官方那条带确认弹窗的通道：点保存后 App 会弹一次它自己的确认，点「允许」才落盘。
  正式包里没有 bypass（`writeFieldsForDebug` 在 `#if DEBUG` 里），也不该绕。
- **v3.1（已完成）**：线路判定补全 —— WiFi / 蜂窝 / 有线 接口识别、换网自动重判、
  自家网段与「别人家 WiFi」的区分、断网跳过探测，见上面「线路怎么判」。
- **v4（本次）**：无感自动换线。本地 HTTP 代理（`RelayProxy`，绑 127.0.0.1:18923）
  常驻，聊天服务商地址固定填 `http://127.0.0.1:18923` 后，请求全部经过代理；
  代理按 `RelayStore` 的实时判定把请求转发到内网 `http://host:8080` 或外网
  `https://域名`，SSE 流式逐块透传。换网、出门、回前台都不用手切模型。
  dylib 加载即启动代理，判定结果由 `RelayStore.refresh()` 推给代理。
  自检页新增「自动换线代理」一节，能看到监听状态 / 当前目标 / 转发计数。
- **v5（本次）**：视觉对齐 fork。
  - 聊天页顶部：浮层窗口顶部盖一条和 fork 1:1 的导航条（实色导航带到 108 +
    15pt 过渡带 + 两行标题 + 左上角白色圆气泡两横线图标）。dylib 拿不到 App
    内部的 SwiftUI 导航条类型，没法真替换，只能用浮层盖；左上角气泡点开管理
    抽屉。标题内容用 dylib 自己能拿到的真值（线路 / 在线状态），不是写死的
    fork 会话名 / 模型名。
  - 设置面板：首页三行换成 fork 设置页的视觉参数 —— 圆角彩色图标块 29×29、
    17pt 标题、13pt 副标题、行高 52、分组标题 13pt/600（见
    `RelaySettingsDesign.swift`，数值照搬 fork 的 `SettingsDesignTokens.swift`）。

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

# 抽屉（Drawer）改造记录

`src/ios/Views/Drawer/` 三个文件的历史决策与踩坑。源码里只保留解释「当前为什么这样写」
的注释，改动编年史都记在这里，按时间倒序。

规则：**同一问题改到第 3 次就先停手，回读本文档，别再盲改系数。**

---

## 结构

```
EdgeDrawer.swift          DrawerState（开合状态）+ DrawerContainer（叠层 + 手势）
SessionDrawer.swift       抽屉里的内容：标题栏、搜索、分组列表、产物折叠、底部操作
ContentView+Drawer.swift  把 iPhone 的 stackLayout 包进 DrawerContainer；关掉系统返回手势
```

---

## R81 — 卡片铺到顶、上下都长圆角

用户反馈三连：齿轮快没了、滑到右边文字太清晰背景太白、卡片下面缺的那条露出来
但缺圆角、上面那条没到顶但有圆角。

根因是 **ZStack 的尺寸语义**：卡片是「和屏幕等高的板」，比父容器（安全区那块）
高一截。`ZStack` 按**最大子视图**定自己的尺寸 → ZStack 长到整屏高 → 整层被
GeometryReader 顶到安全区顶 → 纵向默认居中 → 整层往下坠一个状态栏高度。
表现就是顶上缺一条、底下溢出被裁、抽屉跟着下坠 46pt 把右下角齿轮推出屏幕。

修法两条：

1. `ZStack(alignment: .topLeading)` —— 纵向按顶边对齐，位置不再依赖
   「父子两边高度差」的推导；
2. 末尾 `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)`
   把 ZStack 钉死在父容器给的尺寸上，不让它被子视图撑大。

配套：卡片 `offset(y: -(m.top))`。**不要再写 `(bottom - top) / 2`** —— 那个式子
的前提是「容器居中摆一个比自己高的子视图」，前提本身不成立，所以越修越歪。

蒙底系数 0.34 → 0.55：0.34 只做到「隐约看得出有字」，真机正文字号小、行距密，
白蒙不住笔画还是一眼能读。

> **踩过的坑**：`.frame(width:maxHeight:)` 不是合法重载（编译报
> `extra argument 'width'`）。要拆成 `.frame(width:)` 再 `.frame(maxHeight:)`。

---

## R80 — 滑动卡顿 / 手机发热

三个独立原因，各自修：

### 1. 抽屉订阅了 DrawerState

抽屉里几十行会话 + 分组头 + 产物折叠区，全部 `@EnvironmentObject` 订阅了
`DrawerState`。`progress` 拖动时每帧都变 → 整棵树每帧重算。抽屉实际只需要
「点完之后收起来」，于是改成 `DrawerCloseAction`：一个不被订阅的类，里面放闭包，
走环境传下去。类实例用 `@State` 存、跨 body 重算不变 → 环境值不变 → 不触发重算。

### 2. body 里现造闭包

`DrawerContainer` 的 drawer / content 原来是两个 `@ViewBuilder` 闭包存成属性，
body 每重算就调一次 → 产出的 View 每帧都是新的（新闭包、新数组）→ SwiftUI
判不出相等 → 每帧重建聊天界面和整个抽屉。改成 **init 里求值存成 let**。

### 3. 模糊 + 逐帧变阴影

`.blur(radius: 2.5 * progress)` 是离屏渲染：每帧把 1290×2796 整屏重做一遍
高斯卷积，半径还在连续变 → 等于每帧重算一张整屏位图。彻底删掉，换成
`.overlay` 蒙一层 `systemBackground`，只改 alpha，GPU 一次混合。

阴影同理：`radius` / `offset` 固定成终值，只让 alpha 跟 progress 走。

### 4. 结构性问题

「点空白关闭」那层原来用 `if state.isOpen` 包着 —— `if` 是结构性条件，越过
progress 0.5 那一刻 ZStack 子视图列表多一个/少一个，SwiftUI 要重建容器，
正好发生在拖动中段，手感是「滑到一半顿一下」。改成常驻 + `allowsHitTesting`。

> 不用 `.opacity(1 - k * progress)`：卡片不透明，整张降透明度会把底下的抽屉右缘
> 和窗口底色透上来，浅色模式下变成一块脏灰。蒙自己的底色只降内容对比度、
> 不动底色，观感才是「字变浅」而不是「卡片变薄」。

---

## R79 — 上下各缺一条（第一版，失败）

`geo.safeAreaInsets` 在这棵树上是 **0**。把它当出血量往下传等于什么都没做，
真机上画面一点变化都没有。窗口自己的 `safeAreaInsets` / `bounds` 是 UIKit
实测值，不经过 SwiftUI 布局，不会被抹成 0 —— 改用 `windowMetrics()`。

顺带一个好处：窗口安全区**不含键盘**。走 SwiftUI 安全区的话键盘一弹
`bottom` 会变成 300 多，卡片被撑到屏幕外。

---

## R78 / R76 — 出血两条弯路

- R76：给 `content()` 加 `.ignoresSafeArea(edges: .vertical)` —— 无效，
  `NavigationStack` 内部按 safeArea 重新布导航栏，外层 frame 没动；
- R78：靠「负 padding + `geo.safeAreaInsets`」撑出去 —— 无效，理由同 R79。

最终方案：出血量从窗口拿 + 用硬 `.frame(height:)` 撑到整屏高 + 里面的 content
自己上下加 padding 退回安全区（导航栏、返回键、列表 inset 一点不动）。

---

## R77 — 右滑先退回列表，再滑一次才出抽屉

`InteractivePopGestureDisabler` 一个人不够，两个原因：

1. **它根本找不到导航控制器**。它用 `.background()` 挂在 NavigationStack 上，
   而 background 在导航栈**外面** —— 沿响应链 `next` 上溯走的是
   「background → hosting view → 窗口」，永远碰不到 `UINavigationController`。
   找不到就静默返回，一个手势都没关掉。
2. **就算找到了也会被系统重新打开**。`UINavigationController` 在栈深变化时
   （push 完一个页面）会把 `interactivePopGestureRecognizer.isEnabled` 重置回 true。

所以用两层：`isEnabled = false` + `require(toFail: open/close)`。后者是挂在
手势对象上的永久失败依赖，UIKit 重置 `isEnabled` 不会清掉。

`ContentView+Drawer.swift` 里的 `InteractivePopGestureDisabler` 保留为次要防线
（它可能沿响应链碰不到导航控制器，但拆掉没有收益、只有回归风险）。

只处理主栈（`rootViewController` 及其 children），**不递归
`presentedViewController`** —— 设置页是 sheet、自带一个 NavigationStack，
关掉它的返回手势用户就退不回去了。

---

## R75 — 手势改全屏

用户要：「聊天界面任意位置向右滑出抽屉，任意位置向左滑收回来」。
原版只能左边缘 44pt。

**pan 全部挂 `UIWindow` 上**，不挂任何 UIView。`UIGestureRecognizer` 不参与
hitTest —— 挂 window 能做到「全屏判定 + 一个像素都不挡」；挂在 UIView 上就必须
让那个 view 吃掉触摸（`point(inside:)` 返回 true），结果是抽屉里的会话行、
齿轮、输入框全点不动。

配套两条判定：

- 起手点在 `safeAreaInsets.top + 44` 以上 → 不接管（返回键 `‹` 和通知中心让给系统）；
- 水平速度必须 > 垂直速度 × **1.3**。只写 `abs(x) > abs(y)` 的话，一次 45° 斜划
  就会把抽屉拉出来，观感是「想滚一下，界面却动了」。

手势常驻、不做「开着挂关了摘」：progress 是连续值，拖到 0.02 以下时摘手势会让
UIKit 立刻发 `.cancelled`，手感是「卡住不跟手」。

---

## R74 — 抽屉点不动

「点空白关闭」那层原来挂在 `content()` 的 `.overlay` 里。`.overlay` 按父视图的
**布局 frame** 定位，不跟随 `.offset` 的视觉位移 —— 而 content 的布局 frame 是全屏，
所以那层 `Color.clear` 实际铺满整屏，左边露出来的抽屉也在它底下。触摸先到它、
被 onTapGesture 接住、执行 close()，看起来就是「点聊天界面就回来了」。

改成 ZStack 里独立一层，左侧显式空出 `drawerWidth` 且 `allowsHitTesting(false)`。

---

## R68 — 宽度改成「屏宽 − 54」

原来是「占屏宽 78%、上限 318」，右侧那条太宽。参照（WorkBuddy 手机端）右侧那条
明显更窄：能认出是聊天内容，但读不清。

```
抽屉宽 = max(min(屏宽 − 54, 348), 屏宽 × 62%)
       393pt（15/16/17）：339，右侧留 54
       402pt（16 Pro）  ：348 触顶，右侧留 54
       440pt（Pro Max） ：348 触顶，右侧留 92
       320pt（SE）      ：266，右侧留 54
```

348 是「标题 + 摘要 + 时间」还能保持一行的上限。最后那个 62% 只是兜底，
正常机型轮不到。

---

## R67 — 抽屉沉底，聊天界面当卡片被推走

参照原话：「聊天界面在上面，抽屉在底下，从左往右滑是聊天界面在上边走，
露出抽屉，同时走快要到的时候就停，聊天界面有圆角，越走圆角越大」。

所以：抽屉**钉在 0 不动**，聊天界面位移 `drawerWidth * progress`。
早期那版是抽屉自己从 `-drawerWidth` 滑到 0，观感是「一块板从左边推上来」——
动的是抽屉，聊天界面只是被顶开，反了。

层次：抽屉 `zIndex 0`，卡片 `1`，手势宿主 `2`，点空白层 `3`。

---

## 待清理

- `DrawerState.dragging` / `DrawerState.toggle()` 已于 R81 后续删除（零调用）。
- `ContentView.openSessionFromDrawer` 已删除（抽屉走 `menuActions.send(.open)`）。

//
//  EdgeDrawer.swift
//  全能AI - 侧滑抽屉容器
//
//  改造点：原版 iPhone 是 NavigationStack 的「列表页 → push 对话」，
//  列表和对话是两个全屏页面，来回要 push/pop。这里给内容层外面加一层：
//
//      对话是主界面，会话列表变成从左边拉出来的抽屉。
//
//  ============================================================
//  和原版「左滑返回」的关系（必须先看这段）
//  ------------------------------------------------------------
//  原版在对话页从屏幕左边缘右滑，会触发 NavigationStack 的
//  interactivePopGestureRecognizer —— 也就是返回上一页。
//
//  抽屉也要吃右滑，两者天然抢同一次触摸。这里的选择是：**抽屉赢**。
//     · `InteractivePopGestureDisabler`（见 ContentView+Drawer.swift）
//       在抽屉挂着的时候把系统返回手势关掉；
//     · 返回仍然可用 —— 走导航栏左上角的 `‹` 按钮，那是系统原生的，
//       一行没改。
//
//  ============================================================
//  手势规则（R75 起：全屏，不再是「只有左边缘」）
//  ------------------------------------------------------------
//      1. 抽屉关着 —— 屏幕**任意位置**向右滑 → 拉出抽屉
//      2. 抽屉开着 —— 屏幕**任意位置**向左滑 → 收回抽屉
//      3. 点卡片（右侧露出来的那部分）→ 收回抽屉
//      4. 两种情况都要求：水平速度明显大于垂直（1.3 倍），否则让给滚动
//      5. 起手点在状态栏 + 导航栏那一段 → 完全不接管，让给系统
//
//  第 4 条是关键。少了它，在列表里上下滚动会被误判成拉抽屉，或者反过来
//  想拉抽屉时列表跟着滚。用 1.3 倍而不是 1 倍，是因为斜着划（45°）
//  在长列表里太常见了。
//
//  第 5 条也是必须的：全屏手势会盖住左上角的返回键 `‹`，还会碰状态栏
//  下拉通知中心。物理上没法只挖个洞（手势不参与 hitTest，谈不上遮挡），
//  所以在 shouldBegin 里按起手点排除。
//
//  **实现上有一件事必须记住**：所有 pan 都挂在 `UIWindow` 上，不挂在
//  任何一个 UIView 上。原因是 `UIGestureRecognizer` 不参与 hitTest ——
//  挂 window 就能做到「全屏判定 + 一个像素都不挡」，挂在某个 UIView 上
//  则必须让那个 view 吃掉触摸，结果是所有按钮都点不动。
//
//  另一个刻意设计：手势只跟手，不跟动画。拖到一半松手才决定吸附方向
//  （超过 40% 就往完展开 / 收回，否则看速度方向）。这样不会有「拖一下
//  就整块跳过去」的割裂感。
//

import SwiftUI

// MARK: - 抽屉状态

/// 抽屉的开合状态。单独抽成 ObservableObject 而不是往 ContentView 里塞
/// 一个 @State，原因是：
///   - 手势回调是给底层 UIView 的（UIPanGestureRecognizer），闭包里不能直接
///     写 SwiftUI 的 @State binding；
///   - 后面长按菜单、搜索框这些子视图都要读同一个状态，用 EnvironmentObject
///     比一层层传 binding 干净。
@MainActor
final class DrawerState: ObservableObject {

    /// 0 = 完全收起，1 = 完全展开。手势过程中是连续值。
    @Published var progress: CGFloat = 0

    /// 是否正在被手指拖动。用来在手势期间关掉动画，避免和手势打架。
    @Published var dragging = false

    /// 抽屉展开后，**屏右侧留出的那一条**宽度（pt）。
    ///
    /// [R68] 原来是「抽屉占屏宽的 78%、上限 318」。用户给的参照
    /// （WorkBuddy 手机端）右侧那条明显更窄 —— 能认出是聊天内容，
    /// 但读不清。所以改成直接定「右侧留多少」：
    ///
    ///   抽屉宽 = 屏宽 − 54
    ///
    /// 这样 SE(320) 到 Pro Max(440) 上露出来的那条都是同一个宽度，
    /// 大屏不会露一大块、小屏也不会只剩一条缝。
    static let peekStrip: CGFloat = 54

    /// 抽屉宽度上限。
    ///
    /// 「屏宽 − 54」在 Pro Max 上要 386pt，会话标题到右侧时间之间会空掉
    /// 一大截，行看起来是散开的。348 是还能让「标题 + 摘要 + 时间」
    /// 保持一行的上限，超过就按 348 定宽、右侧多留一点。
    static let widthMax: CGFloat = 348

    /// 吸附判定：拖过这个比例就往「展开」吸，否则往「收起」吸。
    static let settleThreshold: CGFloat = 0.4

    /// 导航栏的内容高度（不含状态栏）。
    ///
    /// [R75] 手势改成全屏之后，这个值不再用来「给手势层让位」——
    /// 判定改在 `shouldBegin` 里做，坐标是 window 坐标：
    ///
    ///     起手点 y < window.safeAreaInsets.top + 44  →  不接管
    ///
    /// `safeAreaInsets.top` 是状态栏（刘海机 59pt / 非刘海 20pt），加 44
    /// 正好到导航栏底边，左上角返回键 `‹` 整块热区都归系统。
    ///
    /// 44 是 UINavigationBar 的标准内容高度，iOS 上一直没变过。
    static let navBarHeight: CGFloat = 44

    var isOpen: Bool { progress > 0.5 }

    /// 动画参数。
    ///
    /// `.spring(response:dampingFraction:)` 是 iOS 15+ 的写法，观感是
    /// 「起步跟手、末尾轻微过冲再回正」，最接近系统侧滑返回：
    ///   · response 0.3 → 一次开合大约 300ms，和系统侧滑返回一致；
    ///   · dampingFraction 0.86 → 轻微过冲，不抖。
    ///
    /// 阻尼低于 0.8 会在末尾明显弹一下（像坏了）；高于 0.95 就没有
    /// 那种「吸住」的手感，变成生硬地停住。
    private static let drawerSpring = Animation.spring(response: 0.3,
                                                       dampingFraction: 0.86)

    func open(animated: Bool = true) {
        if animated {
            withAnimation(Self.drawerSpring) {
                progress = 1
            }
        } else {
            progress = 1
        }
    }

    func close(animated: Bool = true) {
        if animated {
            withAnimation(Self.drawerSpring) {
                progress = 0
            }
        } else {
            progress = 0
        }
    }

    func toggle() {
        isOpen ? close() : open()
    }

    /// 手势结束时的吸附。
    func settle(to target: CGFloat) {
        dragging = false
        withAnimation(Self.drawerSpring) {
            progress = target >= Self.settleThreshold ? 1 : 0
        }
    }
}

// MARK: - 容器

/// 把「内容」和「抽屉」叠在一起，并接管全屏侧滑手势。
///
/// 用法：
/// ```swift
/// DrawerContainer(width: geo.size.width, drawer: { SessionDrawer(...) }) {
///     stackLayout
/// }
/// ```
struct DrawerContainer<Drawer: View, Content: View>: View {

    @StateObject private var state = DrawerState()

    /// 抽屉宽度。用固定值而不是比例：抽屉里那些行高、内边距都按
    /// 「一个相当确定的宽度」排的，纯比例会让文字折行位置在机型之间跑掉。
    /// 现在的算法是「屏宽减去右侧要留的那一条」，再受上限约束，见 init。
    private let drawerWidth: CGFloat

    /// 整屏宽度。抽屉态右侧要留一条「点空白关闭」的热区，宽度靠它算。
    private let totalWidth: CGFloat

    private let drawer: (DrawerState) -> Drawer
    private let content: () -> Content

    init(width: CGFloat,
         @ViewBuilder drawer: @escaping (DrawerState) -> Drawer,
         @ViewBuilder content: @escaping () -> Content) {
        self.totalWidth = width

        // [R68] 「屏宽 − 54」定宽，再受 348 上限约束。
        //
        //   393pt 机型（15/16/17）：393 − 54 = 339，右侧留 54；
        //   402pt（16 Pro）      ：348（触顶），右侧留 54；
        //   440pt（Pro Max）     ：348（触顶），右侧留 92；
        //   320pt（SE）          ：320 − 54 = 266，右侧留 54。
        //
        // 最后那个 `max(…, 62%)` 只是兜底：正常机型上都轮不到它，
        // 但万一把窗口拖得极窄（Mac 上的可缩放窗口），也不至于让
        // 抽屉窄到标题都放不下。
        let peek = DrawerState.peekStrip
        let cap = DrawerState.widthMax
        self.drawerWidth = max(min(width - peek, cap), width * 0.62)

        self.drawer = drawer
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // ── 抽屉层（最底下，静止不动）──
            //
            // [R67-抽屉沉底] 用户给的参照（截图 + 原话）：
            //   「聊天界面在上面，抽屉在底下，从左往右滑是聊天界面在上边走，
            //     露出抽屉，同时走快要到的时候就停，聊天界面有圆角，
            //     越走圆角越大」
            //
            // 所以抽屉必须**钉在 0 不动**。原来那版是抽屉自己从
            // `-drawerWidth` 滑到 0（`offset(x: -drawerWidth * (1 - progress))`），
            // 观感是「一块板从左边推上来」—— 动的是抽屉，聊天界面只是被顶开。
            // 现在反过来：抽屉静止在底下，聊天界面像一张卡片被推走，露出它。
            //
            // 层次也倒过来：抽屉 zIndex 0（最底），聊天界面 zIndex 1。
            // 命中测试天然上层优先，所以抽屉露出来的那一条能正常点、
            // 被卡片盖住的部分不会误触；完全收起时卡片盖满全屏，
            // 抽屉那一层根本接不到触摸。
            drawer(state)
                .frame(width: drawerWidth)
                // 收起过程中（progress 还在 0 附近）不参与命中：
                // 否则动画刚起步那一瞬，露出的 1~2pt 会把聊天界面左边缘的
                // 点击吃掉。
                .allowsHitTesting(state.progress > 0.02)
                .zIndex(0)

            // ── 聊天界面（上层卡片）──
            //
            // 四个量都跟着 progress 走：
            //   · 位移 `drawerWidth * progress` —— 上限就是抽屉宽度。
            //     「走快要到的时候停」说的就是这个：走到抽屉宽度停住，
            //     **屏幕右侧永远留一条**（= DrawerState.peekStrip）给用户
            //     看到还有内容；
            //   · 圆角 `24 * progress` —— 0 的时候是方正的一整屏，
            //     一开始滑就长出圆角，越滑越圆，最后是一张完整的卡片。
            //     圆角是「这是一张被推开的纸」的信号，比缩放或淡出都准确；
            //   · 模糊 + 蒙底 —— 见下面 [R68]，越推越浅；
            //   · 阴影跟着圆角一起长，把卡片和底下的抽屉分开 —— 没有它，
            //     卡片边缘和抽屉背景颜色接近时会糊成一片，看不出层次。
            //
            // [R67] 曾经去掉过 R63 加的 blur，理由写的是「模糊和圆角打架、
            // 参照里聊天内容是清晰的」。R68 用户重新给了参照并明确要求
            // 「要和他一样模糊，就感觉字体越走越浅」—— 右侧露出的那一条
            // 确实是虚的。所以补回来，但比 R63 的 4.0 弱：只到 2.5，
            // 目的是把文字化开、不是把整屏糊掉。
            content()
                .blur(radius: 2.5 * state.progress)
                // 「越走越浅」靠这层底色蒙出来。
                //
                // 不用 `.opacity(1 - k * progress)`：卡片是**不透明**的，
                // 整张降透明度会把底下的东西（抽屉右缘、窗口底色）
                // 透上来，浅色模式下卡片会变成一块脏灰。
                // 蒙自己的底色只降内容对比度、不动卡片本身的底色，
                // 观感才是「字变浅了」，而不是「卡片变薄了」。
                //
                // 蒙的是 `systemBackground` 而不是白：深色模式下蒙白会
                // 把深色卡片糊成一片雾。
                .overlay {
                    Color(UIColor.systemBackground)
                        .opacity(0.22 * state.progress)
                        .allowsHitTesting(false)
                }
                // 先蒙再裁：蒙层在 clipShape 里面，圆角外面那圈不会被
                // 糊成方角。
                .clipShape(RoundedRectangle(cornerRadius: 24 * state.progress,
                                            style: .continuous))
                .shadow(color: .black.opacity(0.18 * Double(state.progress)),
                        radius: 18 * state.progress,
                        x: -8 * state.progress,
                        y: 0)
                .offset(x: drawerWidth * state.progress)
                // 抽屉开着时，这张卡片**彻底退出命中链**。
                //
                // 只写 `.disabled(state.isOpen)` 不够：`disabled` 只保证
                // 「控件不响应」，视图本身仍然参与命中，落在卡片布局范围
                // 里的触摸会被它吃掉、不再往下传给抽屉。
                //
                // `.offset` 在 SwiftUI 里会同时移动渲染和命中区域，所以
                // 卡片实际可命中的部分是 (drawerWidth … 屏宽)，正常人点不到
                // 左边抽屉；但设备旋转、分屏、或系统在动画中间做一次命中
                // 快照时，边界会有一帧对不齐。显式关掉最省心。
                .allowsHitTesting(!state.isOpen)
                .disabled(state.isOpen)
                .zIndex(1)

            // ── 点空白关闭（独立一层）──
            //
            // [R74-抽屉点不动] 这一层原来挂在上面 content() 的 `.overlay` 里，
            // 结果抽屉里的会话行、齿轮、搜索框全都点不动，一点就收回抽屉。
            //
            // 原因：`.overlay` 挂在 `.offset` **之后**，而 SwiftUI 的 overlay
            // 是按父视图的**布局 frame** 定位的，不跟随 offset 的视觉位移。
            // content 的布局 frame 是全屏，所以那层 `Color.clear` 实际铺满了
            // 整屏 —— 左边露出来的抽屉也在它底下。触摸先到它，被它的
            // onTapGesture 接住，执行 close()，看起来就是「点聊天界面就回来了」。
            //
            // 现在改成 ZStack 里独立一层，**左侧显式空出抽屉宽度**：
            //   · 左段 drawerWidth 宽 → allowsHitTesting(false)，触摸继续往下
            //     落到 zIndex 0 的抽屉上，抽屉内部一切正常；
            //   · 右段（卡片可见的那部分 + 右侧留的那一条）→ 接住点击并关闭。
            //
            // 这样既不依赖「offset 会不会移动命中区域」这个容易踩坑的行为，
            // 也保住了「点卡片收回抽屉」的手感。
            //
            // zIndex 3 保证它压在最上面（卡片 1、手势宿主 2）。
            //
            // 手势完全不在这里竞争：三个 pan 都挂在 window 上，不参与
            // hitTest，也就不用管谁在上面。「往左拖收回」走的是 closePan。
            if state.isOpen {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: drawerWidth)
                        .allowsHitTesting(false)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { state.close() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(3)
            }

            // ── 手势层（不可见的宿主）──
            //
            // [R75-全屏拖拽] 用户原话：
            //   「在聊天界面的时候滑动屏幕任意位置向右滑动都出来抽屉，
            //     然后在任意位置向左滑动，聊天界面再回来」
            //
            // 所以「拉出」和「收回」都不能再限定在屏幕左边缘那一条上，
            // 手势全部挂到 `window` 上。
            //
            // 为什么挂 window：`UIGestureRecognizer` **不参与 hitTest**。
            // UIKit 的命中测试只问 UIView（`hitTest` / `point(inside:)`），
            // 手势是跟在触摸流上旁听的 —— 触摸照样送到它该去的地方，
            // 手势只是「顺便」判断这次滑动够不够格。
            //
            // 之前那版把 pan 挂在 ZStack 里的一张透明 UIView 上，想让它在
            // 全屏范围接管，就必须让 `point(inside:)` 返回 true，结果是
            // 那层把所有点击吃掉：抽屉里的会话行、齿轮、输入框全点不动。
            // （那层还不敢铺满全屏，于是「拉出」只能退化成左边缘 44pt。）
            // 挂 window 一次性解决两件事：全屏判定 + 一个像素都不挡。
            //
            // 这一层本身缩到 1×1 且 `allowsHitTesting(false)`，唯一职责是
            // 当个能拿到 window 的宿主：`makeUIView` 阶段 window 还是 nil，
            // 靠 `didMoveToWindow` 回调补挂手势。
            EdgePanOverlay(state: state, drawerWidth: drawerWidth)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .zIndex(2)
        }
        .environmentObject(state)
        // 抽屉出来就收键盘。
        //
        // 为什么必须收：抽屉是聊天界面底下的一层，输入框在卡片上。
        // 键盘留着的话，屏幕下半截被键盘占住，抽屉的可视区域只剩一小条，
        // 而且键盘弹出期间系统还会压缩安全区 —— 两个效果叠起来，
        // 抽屉看起来「变小了」。
        //
        // 触发条件用 progress > 0.35 而不是 isOpen（> 0.5）：
        // isOpen 是「已经完全展开」，但用户拉到一半就已经能看见抽屉了，
        // 那时候键盘还挂着就很别扭。0.35 是「明显是在拉抽屉」的位置，
        // 又不会被一次轻微的边缘误触触发。
        .onChange(of: state.progress) { p in
            if p > 0.35 {
                dismissKeyboard()
            }
        }
    }
}

// MARK: - 手势层

/// 一句话收掉键盘。
///
/// 为什么用 `UIApplication.sendAction` 而不是自己找 first responder：
///   · 自己遍历视图树找 `isFirstResponder` 要递归整棵 window，
///     聊天界面里消息列表很长、还在流式输出，递归有代价；
///   · `resignFirstResponder` 传 nil 目标时，UIKit 会按响应链广播，
///     由系统自己找到当前第一响应者 —— 这是官方推荐的收键盘方式，
///     也是 `UIViewController.view.endEditing` 内部在做的事。
///
/// 为什么不直接 `endEditing(true)`：那需要拿到 UIView 引用。这个函数
/// 在 SwiftUI 的修饰符里调用，手上没有视图；`sendAction` 是全局的。
@MainActor
private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil)
}

/// 不可见的 UIKit 宿主，只做一件事：把三个 pan 挂到 window 上。
private struct EdgePanOverlay: UIViewRepresentable {

    @ObservedObject var state: DrawerState
    let drawerWidth: CGFloat

    func makeUIView(context: Context) -> UIView {
        let v = HostView()
        v.backgroundColor = .clear
        // 关键：自己**不接触摸**。
        //
        // 手势全挂在 window 上，跟这个 view 没关系；它留着只为了
        // 「知道什么时候进 window」。所以这里绝不能是可交互的，
        // 否则又会变成那层挡住所有点击的透明板。
        v.isUserInteractionEnabled = false

        context.coordinator.host = v
        // 进 window 的时机补挂手势：makeUIView 阶段 window 还是 nil，
        // `updateUIView` 之后也不一定再被调用（抽屉状态没变就不会）。
        let coord = context.coordinator
        v.onWindowAvailable = { [weak coord] in
            coord?.syncWindowPans()
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.width = drawerWidth
        context.coordinator.state = state
        // window 可能被换掉（SwiftUI 偶尔会把 hosting view 搬到另一个
        // window，比如弹 sheet），所以每次更新都核对一遍。
        context.coordinator.syncWindowPans()
        uiView.backgroundColor = .clear
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, width: drawerWidth)
    }

    /// 只负责「报告自己进了 window」的宿主视图。
    final class HostView: UIView {

        /// 进入 window 后回调。
        ///
        /// `updateUIView` 在视图刚创建那一刻就会跑，那时 `window` 还是
        /// nil，`syncWindowPans` 里的 `guard let window = host?.window`
        /// 会直接返回 —— 手势挂不上。而 `updateUIView` 之后不一定再被调，
        /// 所以必须接一个「进 window」的时机。
        var onWindowAvailable: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onWindowAvailable?() }
        }
    }

    /// 三个 pan 的调度中心。
    ///
    /// 全部挂在 `UIWindow` 上，**常驻**、不跟开合增删。
    ///
    /// 为什么不做「开着就挂、关了就摘」：progress 是连续值，手指把抽屉
    /// 拖到 0.02 以下时 `updateUIView` 会跑，一摘手势 UIKit 立刻发
    /// `.cancelled` —— 手势被打断，用户拖到一半会感觉「卡住不跟手」。
    /// 在阈值附近来回微调更明显，摘、挂、摘、挂，一路 cancelled。
    ///
    /// 常驻的代价几乎为零：手势不参与 hitTest，抽屉关着时它们唯一的
    /// 开销是每次触摸多跑几次 `shouldBegin`，而那里第一件事就是看
    /// progress 和方向。少一个状态，就少一类「摘挂时机」的 bug。
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        var state: DrawerState
        var width: CGFloat

        /// 屏幕物理边缘的「拉出」手势。
        ///
        /// `UIScreenEdgePanGestureRecognizer` 在**触摸按下那一刻**就知道
        /// 落点在不在屏幕边缘，不满足直接不认，满足立刻开始 —— 没有普通
        /// pan 那段「要移动 10pt 才进入 .began」的死区。所以边缘起手的
        /// 零死区手感靠它，屏幕中间那大片靠 openPan。
        weak var edgePan: UIScreenEdgePanGestureRecognizer?

        /// 全屏「拉出」手势：屏幕任意位置右滑都出抽屉。
        weak var openPan: UIPanGestureRecognizer?

        /// 全屏「收回」手势：抽屉开着时任意位置左滑都收回去。
        weak var closePan: UIPanGestureRecognizer?

        weak var host: UIView?

        private var startProgress: CGFloat = 0

        init(state: DrawerState, width: CGFloat) {
            self.state = state
            self.width = width
        }

        /// 把三个手势挂到宿主所在的 window 上。
        func syncWindowPans() {
            guard let window = host?.window else { return }

            if let e = edgePan, let o = openPan, let c = closePan {
                // window 换了就把三个手势一起搬过去，否则它们会留在
                // 旧 window 上，拖动没有任何反应。
                if e.view !== window || o.view !== window || c.view !== window {
                    for g in [e as UIGestureRecognizer, o, c] {
                        g.view?.removeGestureRecognizer(g)
                        window.addGestureRecognizer(g)
                    }
                }
                return
            }

            let edge = UIScreenEdgePanGestureRecognizer(target: self,
                                                        action: #selector(handle(_:)))
            edge.edges = .left
            configure(edge, on: window)
            edgePan = edge

            let open = UIPanGestureRecognizer(target: self,
                                              action: #selector(handle(_:)))
            configure(open, on: window)
            openPan = open

            let close = UIPanGestureRecognizer(target: self,
                                               action: #selector(handle(_:)))
            configure(close, on: window)
            closePan = close
        }

        private func configure(_ g: UIPanGestureRecognizer, on window: UIWindow) {
            g.delegate = self
            // 识别成功也不取消底层视图的 touches —— 按钮绝不受影响。
            g.cancelsTouchesInView = false
            window.addGestureRecognizer(g)
        }

        /// 视图拆掉时务必把手势摘干净。
        ///
        /// window 是长命的（比这个 UIView 活得久），不摘的话它上面会一直
        /// 留着 target 已经释放的 pan —— UIKit 里 target 是 weak 的，
        /// 不会崩，但那个 pan 仍会在每次触摸时跑一遍 shouldBegin。
        func teardown() {
            for g in [edgePan as UIGestureRecognizer?, openPan, closePan] {
                if let g { g.view?.removeGestureRecognizer(g) }
            }
            edgePan = nil
            openPan = nil
            closePan = nil
        }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let translation = g.translation(in: view).x
            let velocity = g.velocity(in: view).x

            switch g.state {
            case .began:
                startProgress = state.progress
                state.dragging = true

            case .changed:
                // 把 translation 归一化成 0…1 的进度增量。
                let delta = translation / max(width, 1)
                var p = startProgress + delta
                p = min(max(p, 0), 1)
                // 手势期间不能带动画，否则会有一帧延迟，看起来像拖不动。
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { state.progress = p }

            case .ended, .cancelled, .failed:
                // 吸附方向：先看速度（快速轻扫），再看位移比例。
                let projected = startProgress + (translation + velocity * 0.18) / max(width, 1)
                state.settle(to: min(max(projected, 0), 1))

            default:
                break
            }
        }

        // MARK: UIGestureRecognizerDelegate

        /// 三个 pan 互斥：谁先 begin 另一个就让位，避免同一次滑动被
        /// 识别两次造成进度跳变。
        ///
        /// 注意这里**连系统手势也一起返回 false**。系统返回手势
        /// （interactivePopGestureRecognizer）在抽屉挂着的时候会被
        /// `InteractivePopGestureDisabler` 关掉，所以正常路径上它
        /// 根本不会参与竞争；万一某条路径漏了关闭，这个 false 也保证
        /// 一次触摸只会被一个手势消费，不会出现「抽屉和返回同时动」。
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }

        /// 决定这次拖动到底算不算「拉 / 收抽屉」。这是整个手势体验的核心。
        ///
        /// 三个手势共用这一段判定（不再各写一支）：
        ///   · edgePan  屏幕物理边缘 → 只能「拉出」
        ///   · openPan  屏幕任意位置 → 只能「拉出」
        ///   · closePan 屏幕任意位置 → 只能「收回」
        /// 前两个的差别只在起手点，方向判定完全一样，分开写必然有一支漏改。
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer,
                  let window = host?.window else { return false }

            // 同一次触摸三个 pan 都会收到 shouldBegin，先 begin 的赢。
            //
            // closePan 不参与这个互斥：它和另外两个由 `progress` 天然互斥
            // （开着才干活 / 关着才干活），而 `shouldBegin` 之后自己的
            // state 会变成 .began，一旦把它算进来，第二次触摸就会被自己挡住。
            if pan !== closePan {
                for other in [edgePan, openPan] where other != nil && other !== pan {
                    if let o = other, o.state == .began || o.state == .changed { return false }
                }
            }

            // 坐标统一用 **window 坐标**。
            //
            // 手势挂在 window 上，`pan.location(in: window)` 就是屏幕坐标，
            // 不再受「宿主 view 被摆在哪」影响 —— 原来那版靠
            // `location(in: host) - translation(in: host)` 反推起手点，
            // 一旦 view 被 padding 到别处就得跟着改，是个易碎点。
            let velocity = pan.velocity(in: window)
            let startY = pan.location(in: window).y - pan.translation(in: window).y

            // 状态栏 + 导航栏那一段不接管。
            //
            // 左上角是系统返回键 `‹`，顶部是状态栏下拉（通知中心），
            // 那一片的所有滑动都让给系统。`safeAreaInsets.top` 是状态栏
            // （刘海机 59pt / 非刘海 20pt），加 44 正好到导航栏底边。
            if startY < window.safeAreaInsets.top + DrawerState.navBarHeight { return false }

            // 方向判定：水平速度必须**明显**大于垂直。
            //
            // 1.3 倍，不是 1.0。聊天页和抽屉里都是纵向长列表，斜着划时
            // 列表必须赢 —— 只写 `abs(x) > abs(y)` 的话，一次 45° 的
            // 斜划就会把抽屉拉出来，观感是「想滚一下，界面却动了」。
            guard abs(velocity.x) > abs(velocity.y) * 1.3 else { return false }

            if pan === closePan {
                // 抽屉关着时这个手势不干活：它常驻挂 window、全屏都是
                // 判定区，不拦就会把聊天页里所有横向滑动吃掉。
                guard state.progress > 0.02 else { return false }
                // 抽屉开着：只认「往左拖」（收回去）。
                return velocity.x < 0
            }

            // 两个「拉出」手势在抽屉开着 / 正在动时一律不接管。
            //
            // 抽屉张着的时候，用户在抽屉里往右划（比如横向滚动一行
            // 附件缩略图）不能被当成「再拉一次」；而「往左拖收回」由
            // closePan 负责，职责不重叠。
            guard state.progress <= 0.02 else { return false }

            // 抽屉关着：必须是往右拖。
            return velocity.x > 0
        }
    }
}

//
//  EdgeDrawer.swift
//  全能AI - 侧滑抽屉容器
//
//  对话是主界面，会话列表变成从左边拉出来的抽屉。
//  历史决策与踩坑记录见 docs/NOTES-drawer.md。
//

import SwiftUI
import UIKit

// MARK: - 抽屉状态

/// 抽屉的开合状态。
///
/// 抽成 ObservableObject 而不是 ContentView 里的 @State：手势回调在 UIKit
/// 闭包里拿不到 SwiftUI binding，而多个子视图要读同一个状态。
@MainActor
final class DrawerState: ObservableObject {

    /// 0 = 完全收起，1 = 完全展开。手势过程是连续值。
    @Published var progress: CGFloat = 0

    /// 抽屉展开后，屏右侧留出的那一条宽度（pt）。
    /// 定「留多少」而不是「占多少」：SE(320) 到 Pro Max(440) 露出的那条一样宽。
    static let peekStrip: CGFloat = 54

    /// 抽屉宽度上限。超过 348 后「标题 + 摘要 + 时间」会散开，不如右侧多留白。
    static let widthMax: CGFloat = 348

    /// 吸附判定：拖过这个比例往「展开」吸，否则往「收起」吸。
    static let settleThreshold: CGFloat = 0.4

    /// 导航栏内容高度（不含状态栏），UINavigationBar 标准值。
    /// 手势用它排除状态栏 + 导航栏那一段，把返回键和通知中心让给系统。
    static let navBarHeight: CGFloat = 44

    var isOpen: Bool { progress > 0.5 }

    /// 起步跟手、末尾轻微过冲，接近系统侧滑返回。
    /// 阻尼低于 0.8 会明显弹一下，高于 0.95 失去「吸住」的手感。
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

    /// 手势结束时的吸附。
    func settle(to target: CGFloat) {
        withAnimation(Self.drawerSpring) {
            progress = target >= Self.settleThreshold ? 1 : 0
        }
    }
}

// MARK: - 抽屉的「关闭」入口

/// 一个**不会被订阅**的关闭入口，专门给抽屉里的视图用。
///
/// `DrawerState.progress` 在拖动时每帧都变，抽屉里任何订阅它的视图都会
/// 每帧重算整棵 body（分组头 + 几十行会话 + 产物折叠区）。抽屉实际只需要
/// 「点完之后把自己收起来」，所以只传一个闭包：类实例用 @State 存，跨 body
/// 重算不变 → 环境值不变 → 不触发重算；闭包本身每帧刷成当前 close。
final class DrawerCloseAction: @unchecked Sendable {

    /// 由容器在每次 body 里刷成当前 DrawerState 的 close。
    var action: (@MainActor () -> Void)?

    @MainActor
    func close() { action?() }
}

private struct DrawerCloseActionKey: EnvironmentKey {
    static let defaultValue = DrawerCloseAction()
}

extension EnvironmentValues {
    /// 抽屉里调它就能收起自己，不需要订阅 `DrawerState`。
    var drawerClose: DrawerCloseAction {
        get { self[DrawerCloseActionKey.self] }
        set { self[DrawerCloseActionKey.self] = newValue }
    }
}

// MARK: - 容器

/// 把「内容」和「抽屉」叠在一起，并接管全屏侧滑手势。
struct DrawerContainer<Drawer: View, Content: View>: View {

    @StateObject private var state = DrawerState()

    /// 抽屉的关闭入口，见 `DrawerCloseAction`。
    @State private var closeAction = DrawerCloseAction()

    /// 这一轮拖拽里键盘是不是已经收过了（见 body 里的 onChange）。
    @State private var keyboardDismissed = false

    /// 上下两条安全区，由 `ContentView` 从根 `GeometryReader` 直接传进来。
    ///
    /// [R86] 为什么不再自己量：这一层试过三套取数办法，全错。
    ///   · `UIApplication.shared.connectedScenes` 找 key window —— 越狱机的状态栏
    ///     插件各有覆盖窗，拿到的是别人的窗口；
    ///   · 自己 `view.window.safeAreaInsets` —— 这台机器上顶部读出来是 **0**；
    ///   · 量自己在窗口里的矩形 —— 量到的是「容器的 frame」，而卡片的子视图是
    ///     被安全区推进去之后才摆的，frame 的原点和子视图的原点差着这 59pt，
    ///     于是量出来 top = 0，卡片一点没动。
    ///
    /// 而 SwiftUI 自己一直知道答案：卡片里的聊天页正是被这 59pt 推进去的
    /// （导航栏落在 59）。同一个值根 `GeometryReader` 同步就能读到，不异步、
    /// 不需要探针、不会有「改了跟没改一样」。
    private let insets: EdgeInsets

    /// 窗口高度（整屏，含上下安全区）。卡片要这么高才是整块板。
    private let windowHeight: CGFloat

    /// 抽屉宽度。固定值而非比例：行高、内边距都按确定宽度排，
    /// 纯比例会让文字折行位置在机型之间跑掉。
    private let drawerWidth: CGFloat

    /// 整屏宽度。抽屉态右侧那条「点空白关闭」的热区靠它算。
    private let totalWidth: CGFloat

    /// 抽屉和内容**在 init 里就求好值**，不存闭包。
    ///
    /// 存闭包的话 body 每重算一次就要调一次，产出的 View 每帧都是新的
    /// （新闭包、新数组），SwiftUI 判不出相等 → 每帧重建聊天界面和整个
    /// 抽屉，这是滑动卡顿和发热的主因。存成值之后拖动期间这两个子树
    /// 一个字都没变，SwiftUI 直接跳过，只改外层变换修饰符（纯 GPU 合成）。
    private let drawer: Drawer
    private let content: Content

    init(width: CGFloat,
         insets: EdgeInsets,
         windowHeight: CGFloat,
         @ViewBuilder drawer: () -> Drawer,
         @ViewBuilder content: () -> Content) {
        self.totalWidth = width
        self.insets = insets
        self.windowHeight = windowHeight

        // 抽屉宽 = 屏宽 − 54，再受 348 上限约束：
        //   393pt（15/16/17）：339，右侧留 54
        //   402pt（16 Pro）  ：348 触顶，右侧留 54
        //   440pt（Pro Max） ：348 触顶，右侧留 92
        //   320pt（SE）      ：266，右侧留 54
        // 最后的 62% 只是兜底，正常机型轮不到（防止极窄窗口下标题放不下）。
        let peek = DrawerState.peekStrip
        let cap = DrawerState.widthMax
        self.drawerWidth = max(min(width - peek, cap), width * 0.62)

        self.drawer = drawer()
        self.content = content()
    }

    var body: some View {
        // 关闭入口每帧刷一次，指向当前 state。实例本身（环境值）不变，
        // 所以不引发重算，变的只是里面那个闭包。
        let s = state
        closeAction.action = { s.close() }

        // 对齐方式必须是 `.topLeading`：卡片和屏幕等高，比父容器（安全区）
        // 高一截，ZStack 按最大子视图定尺寸后自己也会长到整屏高。
        // 纵向默认居中 → 整层往下坠一个状态栏：卡片顶留一条、底部溢出被裁、
        // 抽屉跟着下坠把右下角齿轮推出屏幕。按顶边对齐后位置不再依赖高度差。
        return ZStack(alignment: .topLeading) {
            // ── 抽屉层（最底下，静止不动）──
            //
            // 抽屉钉在 0，聊天界面像一张卡片被推走、露出它。
            // 层次：抽屉 zIndex 0，卡片 1。命中测试上层优先，所以露出来的
            // 那一条能点、被盖住的部分不误触。
            drawer
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity)
                // 抽屉的**布局帧**仍然是安全区那块矩形（这一层 ZStack 被 body
                // 末尾的 `.frame(maxHeight: .infinity)` 钉死在父容器尺寸上）。
                // 状态栏和 home indicator 那两条靠 `SessionDrawer` 的 `paperCap`
                // 画出去 —— `.background` 不参与布局，允许溢出帧外。
                //
                // 不要把这里改成整窗高：抽屉帧底边一挪到屏幕底，齿轮（底边距
                // 常数 16，相对抽屉帧算）就沉进 home indicator 里去了。
                // [R86] 也不再钉 `.frame(height:)` —— 钉了得现算
                // 「窗口高 − 上 − 下」，多一个可能算错的数，而现在根本不需要。
                //
                // 收起过程中不参与命中：动画刚起步露出的 1~2pt
                // 会把聊天界面左边缘的点击吃掉。
                .allowsHitTesting(state.progress > 0.02)
                .zIndex(0)

            // ── 聊天界面（上层卡片）──
            //
            // 四个量跟着 progress 走：
            //   · 位移 drawerWidth * progress —— 到抽屉宽度停住，
            //     屏幕右侧永远留一条（peekStrip）看得见内容；
            //   · 圆角 24 * progress —— 越滑越圆，像一张被推开的纸；
            //   · 变浅 —— 靠蒙一层底色，不靠模糊（见 .overlay）；
            //   · 阴影把卡片和抽屉分开。
            //
            // 卡片是和屏幕等大的板：上移 `insets.top`、高度撑到整窗，
            // 里面的 content 再加同样的 padding 退回安全区 —— 位置和原版
            // 一个像素不差，但卡片的底色（以及它的圆角和阴影）变成从屏幕
            // 最顶上开始，滑走的时候是从状态栏右上方走的，不会再在状态栏
            // 底下留一条。
            ZStack(alignment: .top) {
                Color(UIColor.systemBackground)
                content
                    .padding(.top, insets.top)
                    .padding(.bottom, insets.bottom)
            }
            .frame(width: totalWidth, height: windowHeight, alignment: .top)
            .offset(y: -insets.top)
            // 「越走越浅」靠这层底色蒙出来，只改 alpha，一次合成。
            //
            // 不用 `.opacity`：卡片不透明，整张降透明度会把底下的抽屉右缘
            // 透上来，浅色模式下变成一块脏灰。蒙自己的底色只降内容对比度、
            // 不动底色，观感才是「字变浅」。蒙 systemBackground 而不是白：
            // 深色模式下蒙白会糊成一片雾。
            //
            // 0.55 是参照里的观感：能看出是聊天气泡，读不出任何一句内容。
            // 只调这一个数，不叠第二层黑 —— 多一层就多一遍全屏混合。
            .overlay {
                Color(UIColor.systemBackground)
                    .opacity(0.55 * state.progress)
                    .allowsHitTesting(false)
            }
            // 先蒙再裁：蒙层在 clipShape 里面，圆角外面那圈不会被糊成方角。
            .clipShape(RoundedRectangle(cornerRadius: 24 * state.progress,
                                        style: .continuous))
            // 阴影半径和偏移**不跟 progress 变**，固定成终值只动 alpha：
            // 半径一变系统每帧要按新形状重生成阴影位图。
            .shadow(color: .black.opacity(0.16 * Double(state.progress)),
                    radius: 14,
                    x: -6,
                    y: 0)
            .offset(x: drawerWidth * state.progress)
            // 抽屉开着时卡片彻底退出命中链。`.disabled` 只保证控件不响应，
            // 视图本身仍参与命中会吃掉本该传给抽屉的触摸。
            .allowsHitTesting(!state.isOpen)
            .disabled(state.isOpen)
            .zIndex(1)

            // ── 点空白关闭（独立一层）──
            //
            // 不能挂在 content 的 `.overlay` 里：overlay 按父视图**布局 frame**
            // 定位、不跟随 offset，而 content 布局 frame 是全屏 —— 那层
            // Color.clear 会铺满整屏，把左边露出的抽屉一起盖住，抽屉里
            // 什么都点不动。
            //
            // 所以独立一层并显式空出左侧：左段 drawerWidth 不接触摸（落到
            // 抽屉上），右段接住点击并关闭。
            //
            // 常驻而不是 `if state.isOpen` 包着：`if` 是结构性条件，越过
            // progress 0.5 那刻 ZStack 子视图列表变化要重建容器，正好发生在
            // 拖动中段，手感是「滑到一半顿一下」。
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: drawerWidth)
                    .allowsHitTesting(false)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { state.close() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 关着时整层不接触摸，否则聊天页所有点击都被它吃掉。
            .allowsHitTesting(state.isOpen)
            .zIndex(3)

            // ── 手势层（不可见的宿主）──
            //
            // pan 全挂 `window` 上：`UIGestureRecognizer` 不参与 hitTest，
            // 挂 window 能做到「全屏判定 + 一个像素都不挡」；挂在某个 UIView 上
            // 就必须让它吃掉触摸，结果是所有按钮都点不动。
            //
            // 这一层缩到 1×1 且不接触摸，唯一职责是当个能拿到 window 的宿主
            // （`makeUIView` 阶段 window 还是 nil，靠 didMoveToWindow 补挂）。
            EdgePanOverlay(state: state, drawerWidth: drawerWidth)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .zIndex(2)
        }
        // 把 ZStack 钉死在父容器给的尺寸（安全区那块）上。不加这句，ZStack
        // 会按最大的子视图（整屏高的卡片）定尺寸，抽屉跟着拿到整屏高、
        // 底部多出 bottom 那一截，齿轮又被推出屏幕。
        // `.frame(maxHeight: .infinity)` 只是用满提议尺寸，不会压扁内容；
        // 卡片超出部分照样画出来（SwiftUI 默认不裁），出血不受影响。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environmentObject(state)
        .environment(\.drawerClose, closeAction)
        // 抽屉出来就收键盘：键盘占住下半截 + 压缩安全区，抽屉会显得变小。
        // 用 0.35 而不是 isOpen（0.5）：拉到一半就已经看得见抽屉了。
        // `keyboardDismissed` 是闸：progress 在 > 0.35 区间每帧都变，
        // 不拦的话拖动期间会每秒发 60 次 sendAction。跨过 0.35 收一次，
        // 回到 0.05 以下再复位。
        .onChange(of: state.progress) { p in
            if p > 0.35, !keyboardDismissed {
                keyboardDismissed = true
                dismissKeyboard()
            } else if p < 0.05 {
                keyboardDismissed = false
            }
        }
    }
}

// MARK: - 手势层

/// 一句话收掉键盘。
///
/// 用 `UIApplication.sendAction` 而不是自己找 first responder：遍历视图树
/// 递归整棵 window 有代价（消息列表长、还在流式输出），而
/// `resignFirstResponder` 传 nil 目标时 UIKit 会按响应链广播，
/// 也是 `endEditing` 内部在做的事。
@MainActor
private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil)
}

/// 不可见的 UIKit 宿主，只做一件事：把三个 pan 挂到 window 上。
private struct EdgePanOverlay: UIViewRepresentable {

    /// 刻意**不用** `@ObservedObject`：progress 每变一次就会调
    /// `updateUIView`，而里面要递归找 UINavigationController。
    /// state 引用本身不变，手势也只在回调里读 progress，当普通 let 就够。
    let state: DrawerState
    let drawerWidth: CGFloat

    func makeUIView(context: Context) -> UIView {
        let v = HostView()
        v.backgroundColor = .clear
        // 自己**不接触摸**：手势挂在 window 上跟它无关，它只负责
        // 「知道什么时候进 window」。
        v.isUserInteractionEnabled = false

        context.coordinator.host = v
        let coord = context.coordinator
        v.onWindowAvailable = { [weak coord] in
            coord?.syncWindowPans()
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 值没变就返回。拖动时 body 每帧重算、representable 跟着重建，
        // updateUIView 也每帧被调 —— 真正需要重挂的只有屏宽变了或
        // state 换了实例；窗口被搬走由 HostView.didMoveToWindow 兜。
        let coord = context.coordinator
        guard coord.width != drawerWidth || coord.state !== state else { return }

        coord.width = drawerWidth
        coord.state = state
        coord.syncWindowPans()
        uiView.backgroundColor = .clear
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, width: drawerWidth)
    }

    /// 只负责「报告自己进了 window」的宿主视图。
    ///
    /// `updateUIView` 在视图刚创建时 window 还是 nil，`syncWindowPans` 里的
    /// guard 会直接返回 —— 手势挂不上，而之后不一定会再被调用。
    final class HostView: UIView {

        var onWindowAvailable: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onWindowAvailable?() }
        }
    }

    /// 三个 pan 的调度中心，全部常驻挂在 `UIWindow` 上。
    ///
    /// 不做「开着挂、关了摘」：progress 是连续值，拖到 0.02 以下时摘手势
    /// 会让 UIKit 立刻发 `.cancelled`，手感是「卡住不跟手」，阈值附近来回
    /// 微调更明显。常驻的代价几乎为零 —— 手势不参与 hitTest，关着时每次
    /// 触摸只多跑几次 shouldBegin，而那里第一件事就是看 progress 和方向。
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        var state: DrawerState
        var width: CGFloat

        /// 屏幕物理边缘的「拉出」手势。它在触摸按下那一刻就知道落点，
        /// 没有普通 pan「要移动 10pt 才 .began」的死区。
        weak var edgePan: UIScreenEdgePanGestureRecognizer?

        /// 全屏「拉出」：任意位置右滑都出抽屉。
        weak var openPan: UIPanGestureRecognizer?

        /// 全屏「收回」：抽屉开着时任意位置左滑都收回去。
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
                // window 换了就一起搬过去，否则手势留在旧 window 上，
                // 拖动没有任何反应。
                if e.view !== window || o.view !== window || c.view !== window {
                    for g in [e as UIGestureRecognizer, o, c] {
                        g.view?.removeGestureRecognizer(g)
                        window.addGestureRecognizer(g)
                    }
                }
                bindSystemPopGesture(in: window)
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

            bindSystemPopGesture(in: window)
        }

        /// 让系统的「右滑返回」让位给抽屉。
        ///
        /// 只靠 `InteractivePopGestureDisabler` 不够：它挂在 NavigationStack
        /// 的 `.background()` 上，而 background 在导航栈**外面**，沿响应链
        /// 上溯永远碰不到 UINavigationController；就算找到了，导航栈在栈深
        /// 变化时也会把 `isEnabled` 重置回 true。
        ///
        /// 所以两层缺一不可：
        ///   · `isEnabled = false` —— 直接关掉；
        ///   · `require(toFail:)` —— 永久失败依赖：系统返回手势必须先等
        ///     我们的 pan 失败。这个关系挂在手势对象上，UIKit 重置
        ///     isEnabled 不会清掉。
        ///
        /// 只处理主栈（rootViewController 及其 children），不递归
        /// `presentedViewController`：设置页是 sheet、自带一个 NavigationStack，
        /// 关掉它的返回手势用户就退不回去了。
        private func bindSystemPopGesture(in window: UIWindow) {
            guard let open = openPan, let close = closePan else { return }
            for nav in Self.navigationControllers(in: window.rootViewController) {
                guard let pop = nav.interactivePopGestureRecognizer else { continue }
                pop.isEnabled = false
                pop.require(toFail: open)
                pop.require(toFail: close)
            }
        }

        /// 递归收集主栈里的 UINavigationController（只走 children，
        /// 不走 presented，理由见 `bindSystemPopGesture`）。
        private static func navigationControllers(in vc: UIViewController?) -> [UINavigationController] {
            guard let vc else { return [] }
            var out: [UINavigationController] = []
            if let nav = vc as? UINavigationController { out.append(nav) }
            for child in vc.children {
                out += navigationControllers(in: child)
            }
            return out
        }

        private func configure(_ g: UIPanGestureRecognizer, on window: UIWindow) {
            g.delegate = self
            // 识别成功也不取消底层视图的 touches —— 按钮绝不受影响。
            g.cancelsTouchesInView = false
            window.addGestureRecognizer(g)
        }

        /// 视图拆掉时把手势摘干净。window 比这个 UIView 活得久，不摘的话
        /// 上面会留着 target 已释放的 pan（UIKit 里 target 是 weak，不崩，
        /// 但每次触摸仍会跑一遍 shouldBegin）。
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

            case .changed:
                // translation 归一化成 0…1 的进度增量。
                let delta = translation / max(width, 1)
                var p = startProgress + delta
                p = min(max(p, 0), 1)
                // 手势期间不能带动画，否则有一帧延迟，看起来像拖不动。
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

        /// 三个 pan 互斥：谁先 begin 另一个就让位，避免同一次滑动被识别
        /// 两次造成进度跳变。这里连系统手势也返回 false：系统返回手势
        /// 正常路径上已被关掉，这个 false 兜住漏关的情况。
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }

        /// 决定这次拖动算不算「拉 / 收抽屉」。三个手势共用这一段：
        /// edgePan / openPan 只能「拉出」，closePan 只能「收回」。
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer,
                  let window = host?.window else { return false }

            // 同一次触摸三个 pan 都会收到 shouldBegin，先 begin 的赢。
            // closePan 不参与：它和另外两个由 progress 天然互斥（开着才
            // 干活 / 关着才干活），而 shouldBegin 之后自己 state 会变 .began，
            // 算进来第二次触摸就会被自己挡住。
            if pan !== closePan {
                for other in [edgePan, openPan] where other != nil && other !== pan {
                    if let o = other, o.state == .began || o.state == .changed { return false }
                }
            }

            // 坐标统一用 window 坐标：手势挂在 window 上，
            // location(in: window) 就是屏幕坐标，不受宿主 view 摆放位置影响。
            let velocity = pan.velocity(in: window)
            let startY = pan.location(in: window).y - pan.translation(in: window).y

            // 状态栏 + 导航栏那一段不接管：左上角是返回键 `‹`，
            // 顶部下拉是通知中心。safeAreaInsets.top 是状态栏
            // （刘海机 59 / 非刘海 20），加 44 正好到导航栏底边。
            if startY < window.safeAreaInsets.top + DrawerState.navBarHeight { return false }

            // 方向：水平速度必须**明显**大于垂直，1.3 倍而不是 1.0。
            // 边上都是纵向长列表，斜着划时列表必须赢 —— 只写
            // `abs(x) > abs(y)`，一次 45° 斜划就会把抽屉拉出来。
            guard abs(velocity.x) > abs(velocity.y) * 1.3 else { return false }

            if pan === closePan {
                // 关着时不干活：它常驻挂 window、全屏都是判定区，
                // 不拦就会把聊天页里所有横向滑动吃掉。
                guard state.progress > 0.02 else { return false }
                // 开着：只认「往左拖」。
                return velocity.x < 0
            }

            // 两个「拉出」手势在抽屉开着 / 正在动时一律不接管：
            // 抽屉里横向滚动附件缩略图不能被当成「再拉一次」。
            guard state.progress <= 0.02 else { return false }

            // 抽屉关着：必须往右拖。
            return velocity.x > 0
        }
    }
}

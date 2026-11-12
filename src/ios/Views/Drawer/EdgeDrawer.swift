//
//  EdgeDrawer.swift
//  全能AI - 左边缘抽屉容器
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
//  抽屉用的也是「屏幕左边缘 + 向右滑」，两者天然抢同一次触摸。
//  这里的选择是：**抽屉赢**。
//     · `InteractivePopGestureDisabler`（见 ContentView+Drawer.swift）
//       在抽屉挂着的时候把系统返回手势关掉；
//     · 返回仍然可用 —— 走导航栏左上角的 `‹` 按钮，那是系统原生的，
//       一行没改。
//
//  为什么不是「两者共存、按速度或位移区分」：这两个手势的起手区域
//  完全重合（屏幕左边缘），任何阈值区分都会在某一档手感下变得
//  时灵时不灵。定死归属比调参数可靠。
//
//  ============================================================
//  手势优先级（三层，写死）
//  ------------------------------------------------------------
//      1. 抽屉开着时 —— 只有「拖回」和「点遮罩关闭」有效，内容区不吃手势
//      2. 抽屉关着时 —— 只有从屏幕左边缘 44pt 内起手才算拉抽屉
//      3. 任何情况下 —— 水平位移必须明显大于垂直位移，否则让给滚动
//
//  第 3 条是关键。少了它，在列表里上下滚动会被误判成拉抽屉，或者反过来
//  想拉抽屉时列表跟着滚。
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

    /// 抽屉宽度占屏幕宽度的比例上限。
    /// 318pt 是定下来的：320pt 的屏幕上要留一点右边让用户看到还有内容，
    /// 402pt 的 Pro Max 上 318 刚好能放下「标题 + 摘要 + 时间」三行不折。
    static let widthFraction: CGFloat = 0.78
    static let widthMax: CGFloat = 318

    /// 从屏幕左边缘起手多少点之内才算「拉抽屉」。
    ///
    /// 44pt 覆盖了绝大多数单手握持时拇指能自然够到的范围，同时还没到
    /// 「吃掉内容点击」的程度 —— 聊天页左边缘这条 44pt 里几乎不放
    /// 可点控件，误伤成本很低。
    ///
    /// 注意：这个值同时也是「系统返回手势被关掉之后」的安全余量。
    /// 系统返回手势的识别区约 20pt，44 把它整个包住了。
    static let edgeSlop: CGFloat = 44

    /// 吸附判定：拖过这个比例就往「展开」吸，否则往「收起」吸。
    static let settleThreshold: CGFloat = 0.4

    /// 系统导航栏高度。手势层要在垂直方向让出这一段。
    ///
    /// 44 是 UINavigationBar 的标准内容高度（不含状态栏）。
    /// 手势层的父容器由 ContentView 的 GeometryReader 给出、未 ignoresSafeArea，
    /// 坐标原点正好在安全区顶部 = 导航栏顶边，所以本地 0…44 就是导航栏。
    ///
    /// 刻意不在这里加 `safeAreaInsets.top`：那是窗口坐标里的量，
    /// 加到视图坐标上会变成跨坐标系相加的错。
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

/// 把「内容」和「抽屉」叠在一起，并接管左边缘手势。
///
/// 用法：
/// ```swift
/// DrawerContainer(width: geo.size.width, drawer: { SessionDrawer(...) }) {
///     stackLayout
/// }
/// ```
struct DrawerContainer<Drawer: View, Content: View>: View {

    @StateObject private var state = DrawerState()

    /// 抽屉宽度。用固定值而不是比例：抽屉里那些行高、内边距都是按 318
    /// 排的，跟着屏幕宽度变会让文字折行位置跑掉。320pt 的老机型上会
    /// 自动收窄，见 init。
    private let drawerWidth: CGFloat

    /// 整屏宽度。抽屉态右侧要留一条「点空白关闭」的热区，宽度靠它算。
    private let totalWidth: CGFloat

    private let drawer: (DrawerState) -> Drawer
    private let content: () -> Content

    init(width: CGFloat,
         @ViewBuilder drawer: @escaping (DrawerState) -> Drawer,
         @ViewBuilder content: @escaping () -> Content) {
        self.totalWidth = width

        // 固定 318。只有屏幕本身放不下（< 390）时才按比例收，
        // 这时抽屉会略窄于设计值 —— 比让它溢出屏幕好。
        let fixed: CGFloat = DrawerState.widthMax
        self.drawerWidth = width >= fixed + 72 ? fixed : min(width * 0.82, fixed)

        self.drawer = drawer
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // ── 内容层 ──
            // 抽屉拉出时内容轻微右移并缩小，做出「被压在后面」的层次感。
            content()
                .scaleEffect(1 - 0.06 * state.progress, anchor: .trailing)
                .offset(x: drawerWidth * state.progress)
                .disabled(state.isOpen)

            // ── 遮罩层（独立，盖满全屏，点任意抽屉外区域关闭）──
            //
            // 之前遮罩挂在 content() 的 .overlay 里，跟着 content 一起被
            // .disabled(state.isOpen) 禁用掉，onTapGesture 收不到点击，
            // 于是「点抽屉外面收不回抽屉」，只能点抽屉右上角的 xmark。
            //
            // 独立成 ZStack 里的一层后：
            //   · 不受 content 的 disabled 影响，点击永远有效；
            //   · frame 铺满全屏，抽屉（drawerWidth 内）由抽屉层自己接住
            //     点击，遮罩实际只盖「抽屉以外」的区域 —— 语义正好是
            //     「点抽屉以外任意地方都收回」。
            if state.progress > 0.02 {
                Color.black
                    .opacity(0.32 * Double(state.progress))
                    .contentShape(Rectangle())
                    .onTapGesture { state.close() }
                    .allowsHitTesting(true)
                    .zIndex(1)
            }

            // ── 抽屉层 ──
            drawer(state)
                .frame(width: drawerWidth)
                .offset(x: -drawerWidth * (1 - state.progress))
                // 抽屉完全收起时不要参与命中测试，否则它的右边缘会
                // 挡住内容区左侧 1pt，点击会莫名没反应。
                .allowsHitTesting(state.progress > 0.02)
                // 必须高于遮罩层（zIndex 1），否则抽屉里的会话行、
                // 齿轮、xmark 会被遮罩盖住点不到。
                .zIndex(2)

            // ── 手势层 ──
            // 单独铺一层透明的 UIView 承载 UIPanGestureRecognizer。
            // 不用 SwiftUI 的 DragGesture 是因为它拿不到「起手点在不在屏幕
            // 左边缘」—— DragGesture 只给相对位移，而我们需要绝对坐标来判断
            // 是否从边缘起手。混用 UIKit 手势识别器是这里最省事的做法。
            //
            // 这一层必须**只占左边缘那一条**，不能铺满全屏。
            //
            // 之前试过全屏 frame + allowsHitTesting(true)，靠
            // `PassthroughView.point(inside:)` 在远离左边缘处返回 false 来
            // 放行触摸。这在纯 UIKit 里成立（hitTest 会跳过返回 nil 的
            // subview 继续找兄弟），但这里不成立：ZStack 里的其它内容由
            // SwiftUI 画在 layer 上，不是能接住 hitTest 的兄弟 UIView。
            // 于是 nil 没有东西可回退，这一次触摸被直接丢弃。
            //
            // 症状：边缘右滑拉抽屉一切正常，但整页所有按钮都点不动。
            // 因为手势层自己是活的，所以看起来像「只有点击坏了」。
            EdgePanOverlay(state: state, drawerWidth: drawerWidth)
                .frame(width: DrawerState.edgeSlop)
                // 手势层从导航栏下方开始，**不覆盖导航栏**。
                //
                // 为什么必须物理避让，而不是继续在 hitTest 里挖洞：
                // 这层是 ZStack 里的一张透明 UIView，盖在系统导航栏上方。
                // `hitTest` 返回 nil 想「放行」，但 SwiftUI 的内容不是它的
                // 兄弟 UIView（是画在同一层 hosting view 里的），nil 没有
                // 接收者可以回退 —— 触摸被直接丢弃，而不是穿透。
                // 于是返回键热区（x≈0~50）只剩 x>44 那一小条能点到，
                // 用户看到的就是「只有一个固定的小点能按」。
                //
                // 让出导航栏后，左上角返回键整块热区恢复成系统原样：
                // 图标四周都能按，和原版一致。代价只是导航栏那 44pt 高的
                // 左边缘不能再起手拉抽屉 —— 那本来就该让给返回按钮。
                //
                // 数值用视图坐标：本容器由 ContentView 的 GeometryReader
                // 包着、没有 ignoresSafeArea，坐标原点就在安全区顶部，
                // 所以导航栏恰好占本地 0…44，不需要再加状态栏高度。
                //
                // ⚠️ padding 必须在 `maxHeight: .infinity` **之前**：
                // 反过来写的话，内层已经撑满父高，padding 再把整体顶高 44，
                // 超出的部分会被 ZStack 垂直居中，顶部反而多盖回来一截。
                // 先 padding 后撑满，父级只会给内层分配 (高 − 44)。
                .padding(.top, DrawerState.navBarHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // 忽略键盘安全区。
                //
                // 键盘弹起时 SwiftUI 会把安全区底部上移，这个手势层的
                // 高度跟着被压短 —— 键盘上方那一段左边缘就变成死区，
                // 「有键盘时左滑拉不出抽屉」。
                //
                // 这里要的是「整屏左边缘都能起手」，键盘在不在与手感
                // 无关，所以两个方向都忽略键盘 inset。
                .ignoresSafeArea(.keyboard, edges: .vertical)
        }
        .environmentObject(state)
        // 抽屉出来就收键盘。
        //
        // 为什么必须收：抽屉是盖在聊天界面上的侧栏，输入框在它下面。
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

/// 透明的 UIKit 视图，只做一件事：识别左边缘右滑 / 抽屉内左滑。
private struct EdgePanOverlay: UIViewRepresentable {

    @ObservedObject var state: DrawerState
    let drawerWidth: CGFloat

    func makeUIView(context: Context) -> UIView {
        let v = PassthroughView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        // 初次创建时抽屉是收起的，边缘窄带宽度立刻生效。
        v.edgeSlop = DrawerState.edgeSlop
        v.activeWidth = 0

        let pan = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        // 换成边缘手势，而不是普通 pan。
        //
        // 这是「手感」的真正来源，不是调阈值能解决的：
        //
        // 原来用普通 UIPanGestureRecognizer，它要等手指移动超过系统内部
        // 的最小距离（约 10pt）才进入 .began，然后再调 delegate 判断
        // 起手点。所以从按下到抽屉开始动，中间永远有一段死区 ——
        // 觉就是「不灵敏、不丝滑」。
        //
        // 原版左滑返回用的是 UIScreenEdgePanGestureRecognizer：
        // UIKit 在**触摸按下那一刻**就知道这次落点在不在屏幕边缘，
        // 不满足就直接不认，满足就立刻开始 —— 没有那段死区。
        // 换过来之后，起手判定交给系统，我们也不用再反推起手点。
        pan.edges = .left
        pan.delegate = context.coordinator
        // 不和内容区的滚动手势抢：真正要接管时由 delegate 决定。
        pan.cancelsTouchesInView = false
        v.addGestureRecognizer(pan)
        context.coordinator.edgePan = pan

        // 兜底手势。
        //
        // UIScreenEdgePanGestureRecognizer 只认落点在屏幕物理边缘
        // ~20pt 内的触摸。手指落点落在 20~44pt（edgeSlop）之间时，
        // 边缘手势直接不认 —— 这次滑动就丢了。拇指自然落点经常
        // 在这个区间，于是「滑了好几遍才出来」。
        //
        // 兜底：加一个普通 UIPanGestureRecognizer，由 shouldBegin 判断
        //   · 起手点（location - translation）在 edgeSlop 带内
        //   · 方向往右（拉出）
        // 两个手势不会重复触发：边缘手势 begin 后，兜底手势的
        // shouldRecognizeSimultaneouslyWith 返回 false 会自然让位；
        // 反过来兜底先 begin，边缘手势也会被同样的互斥挡住。
        let fallback = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        fallback.delegate = context.coordinator
        fallback.cancelsTouchesInView = false
        v.addGestureRecognizer(fallback)
        context.coordinator.fallbackPan = fallback

        context.coordinator.host = v
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.width = drawerWidth
        context.coordinator.state = state

        // 这里**不要**去给 PassthroughView.activeWidth 赋值。
        //
        // 看着很自然的写法是：抽屉开着就 activeWidth = drawerWidth，
        // 让 point(inside:) 返回 true，用户就能从屏幕任意位置往左拖回去。
        // 结论是不能这么干：EdgePanOverlay 在 ZStack 最上层，
        // point(inside:) 一旦全返回 true，这层就把所有触摸吃掉了 ——
        // 遮罩的 onTapGesture 收不到、抽屉里的会话行/齿轮/按钮全点不动，
        // 抽屉彻底废掉。hitTest 返回自己之后触摸不会转给兄弟视图，
        // 这不是 cancelsTouchesInView = false 能解决的（那个只影响
        // 「手势识别成功后是否取消 touchesBegan」）。
        //
        // 现在的行为（activeWidth 恒 0）是：抽屉关着时左边缘 44pt 能拉开，
        // 拉开后点遮罩或点标题栏都能关，只是不能从中间往左拖回去。
        // 属于「缺一个手势入口」，不是「点不动」，可接受。
        uiView.backgroundColor = .clear
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, width: drawerWidth)
    }

    /// 只有触摸落在「实际可交互区域」时才让 UIKit 认这个手势。
    ///
    /// `PassthroughView.hitTest` 返回 nil 让触摸穿透到下面的内容 ——
    /// 但手势识别器是加在这层上的，一旦穿透就不再收到触摸。
    /// 所以这里换了个思路：视图本身可命中，但只在自己「该管」的区域
    /// 返回自己，其余返回 nil。判断逻辑放在 `point(inside:)` 里。
    final class PassthroughView: UIView {
        var activeWidth: CGFloat = 0          // >0 表示抽屉开着，整片可接管
        var edgeSlop: CGFloat = DrawerState.edgeSlop

        /// 这一点是否落在顶部导航栏区域内。
        ///
        /// 先把触点转到**窗口坐标**，再和窗口自己的
        /// `safeAreaInsets.top + 44`（状态栏 + 导航栏标准高度）比较。
        /// 同一坐标系内相减，结果不随视图被摆在哪而漂移。
        func isInNavBar(_ point: CGPoint) -> Bool {
            guard let win = window else { return false }
            let inWindow = convert(point, to: win)
            return inWindow.y < win.safeAreaInsets.top + 44
        }

        /// 导航栏区域直接穿透（返回 nil），把触摸完整交给系统
        /// 返回键 / 系统手势。
        ///
        /// 只在 `point(inside:)` 里「挖洞」是不够的：point(inside:) 返回
        /// false 后 UIKit 仍可能继续命中这个视图的其它部分，边缘手势照样在
        /// window 层被触发，所以返回键始终点不干净。
        /// hitTest 返回 nil 是更彻底的一层：视图直接退出命中链，落在
        /// 导航栏里的 tap 落到系统返回键，抽屉手势完全不参与。
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if isInNavBar(point) {
                return nil
            }
            return super.hitTest(point, with: event)
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            if activeWidth > 0 {
                // 抽屉开着：整片都可接管（用于拖回）
                return true
            }
            // 抽屉关着：只有左边缘一条窄带
            return point.x <= edgeSlop
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        var state: DrawerState
        var width: CGFloat
        /// 屏幕物理边缘手势（零死区，优先）。
        weak var edgePan: UIScreenEdgePanGestureRecognizer?
        /// 兜底普通 pan：接管落点在边缘带内但不在最边缘的滑动。
        weak var fallbackPan: UIPanGestureRecognizer?
        weak var host: PassthroughView?

        private var startProgress: CGFloat = 0

        init(state: DrawerState, width: CGFloat) {
            self.state = state
            self.width = width
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
                // 只有在抽屉「该跟手」的时候才更新进度。
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

        /// 两个 pan（边缘 + 兜底）互斥：谁先 begin 另一个就让位，
        /// 避免同一次滑动被识别两次造成进度跳变。
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

        /// 决定这次拖动到底算不算「拉抽屉」。这是整个手势体验的核心。
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let view = pan.view else { return false }

            // 另一个 pan 已经在跟手时，这个不重复接。
            // （同一次触摸两个手势都会收到 shouldBegin，先 begin 的赢。）
            if g === edgePan, fallbackPan?.state == .began || fallbackPan?.state == .changed { return false }
            if g === fallbackPan, edgePan?.state == .began || edgePan?.state == .changed { return false }

            let v = pan.velocity(in: view)
            let isOpen = state.progress > 0.02

            // 起手点在导航栏区域（返回键 ‹ 那一行）时，不接管 ——
            // 让系统返回键用。边缘手势本来就有 hitTest 挖洞挡住，
            // 兜底手势没那个保护，这里必须自己判一次，否则手指按在
            // 返回键上滑动会误触拉抽屉。
            if let host = host {
                let startY = pan.location(in: host).y - pan.translation(in: host).y
                if host.isInNavBar(CGPoint(x: 0, y: startY)) { return false }
            }

            if isOpen {
                // 抽屉开着：只认「往左拖」（收回去）。
                // 这里是纯方向判断，不做垂直比例过滤 —— 抽屉开着时
                // 整个左边缘都归抽屉，纵向滑动本来也不该发生。
                return v.x < 0
            }

            // 抽屉关着：必须是往右拖。
            //
            // 兜底 pan 要多判一个「起手点在边缘带内」：
            // 它没有 edges 过滤，全屏都会收到回调。用
            // `location - translation` 反推起手点（pan 进入 .began 时
            // translation 还很小，误差可忽略），不在 edgeSlop 带内
            // 就让给内容区 —— 否则聊天页中间往右滑也会拉开抽屉。
            if g === fallbackPan {
                let loc = pan.location(in: view)
                let startX = loc.x - pan.translation(in: view).x
                guard startX <= DrawerState.edgeSlop else { return false }
            }

            // 只留方向判定。垂直位移大于水平时让给内容区的滚动 ——
            // 边缘手势理论上不会和纵向滚动冲突，但抽屉里那个会话列表
            // 是纵向的，斜着划时不要抢它是必要的。
            guard abs(v.x) > abs(v.y) else { return false }
            return v.x > 0
        }
    }
}

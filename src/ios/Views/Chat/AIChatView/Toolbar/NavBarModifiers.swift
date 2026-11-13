//
//  NavBarModifiers.swift
//  Minis - chat page (AIChatView)
//
//  Navigation bar modifiers: NavTitleFrameModifier (also used by
//  HelperTranscriptPage) and NavBarStyleModifier (bar appearance and the top
//  safe-area inset the page reads).
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Nav Bar Modifiers

// [T-agent-transcript-navbar] Shared with HelperTranscriptPage; logic unchanged.
struct NavTitleFrameModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // [NavTitleTopClip 2026-07-23] The principal titleView aligns to the
            // liquid-glass navbar's ~44pt band. Give it 46pt centered so tall
            // title glyphs (semibold 16pt + CJK/caps ascenders) render in full.
            //
            // [NavTitleTransitionClip 2026-07-23] Do NOT `.clipped()`. During a
            // push/pop transition the system interpolates the principal item's
            // frame/scale/alpha; a hard clip rectangle cuts the mid-transition
            // frames along the 46pt box far more aggressively than the steady
            // state (users saw the title sliced to half a line during the
            // animation). The 46pt frame only *sizes* the item for band
            // alignment — the 3-row stack's natural height already fits within
            // it at steady state (spacing -2, ~44pt), so there is nothing to clip
            // away, and letting transition frames render uncropped restores the
            // standard system title transition.
            content
                .frame(height: 46, alignment: .center)
        } else {
            content
        }
    }
}

// [T-agent-transcript-navbar] Shared with HelperTranscriptPage; logic unchanged.
struct NavBarStyleModifier: ViewModifier {
    @Binding var topSafeAreaInset: CGFloat

    /// [T-agent-transcript-navbar-lost] When false, the iOS 16-18 branch skips
    /// the safe-area measuring overlay entirely.
    ///
    /// That overlay writes `topSafeAreaInset` from an `onGeometryChange`
    /// action. A tool sheet presented from OUTSIDE the page's NavigationStack
    /// (SheetOverlayView, a child VC of the message list) changes the top inset
    /// as it presents and dismisses, so the action fires DURING the dismissal's
    /// view-graph update. On the agent transcript page that update ends with
    /// SwiftUI calling `setNavigationBarHidden(true, animated: false)` -- an
    /// all-SwiftUI call stack, no app frames, once per dismissal,
    /// deterministically -- and the bar never comes back.
    ///
    /// `topSafeAreaInset` has no readers on either page: the one site that
    /// would use it deliberately prefers a constant (see slashPickerTopReserve),
    /// so on the transcript page the overlay is pure cost. The main chat keeps
    /// it (default true) rather than change behaviour that is not implicated.
    var measuresSafeArea: Bool = true

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26, *) {
                // iOS 26: extend content behind nav bar so liquid-glass has
                // something to show through; the collection view's
                // contentInsetAdjustmentBehavior = .automatic keeps messages
                // starting below the bar.
                content
                    .ignoresSafeArea(.container, edges: .top)
                    .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                    // [T-macos27-liquid-glass-navbar] See MacOS27GlassWorkaround in
                    // ContentView. `toolbarBackgroundVisibility(.visible)` only
                    // declares "there should be a backdrop"; the material is still
                    // produced by glass sampling — which does not render in a
                    // foreground window on macOS 27, leaving the bar fully
                    // transparent. Pin an opaque colour here instead (the same one
                    // the iOS 16–18 branch below uses). The message list is a
                    // UIKit-hosted UICollectionView, so the modifier's
                    // scrollEdgeEffectHidden is a no-op for it; what does the work
                    // here is toolbarBackground. No change needed in
                    // MessageListViewController.
                    .modifier(MacOS27OpaqueNavigationBar(background: ChatColors.background))
            } else {
                // iOS 16–18: opaque navbar background
                content
                    .toolbarBackground(ChatColors.background, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .overlay(alignment: .top) {
                        if measuresSafeArea {
                            // [T-ios-geometry-observer-crash] onGeometryChange
                            // replaces the GeometryReader scaffold (async-renderer
                            // SIGTRAP — see the floating-bar site). The proxy
                            // measures the same Color.clear the reader wrapped;
                            // ignoresSafeArea/frame stay outside it exactly as
                            // before, and the action's initial fire covers the old
                            // onAppear seed.
                            Color.clear
                                .onGeometryChange(for: CGFloat.self) { proxy in
                                    proxy.safeAreaInsets.top
                                } action: { topSafeAreaInset = $0 }
                                .ignoresSafeArea()
                                .frame(height: 0)
                        }
                    }
            }
        }
        // 导航栏底边那条 1px 分隔线，两个分支都要摘。
        .background {
            NavBarSeparatorRemover()
                .frame(width: 0, height: 0)
        }
    }
}

// MARK: - 导航栏圆形气泡

/// 导航栏左右两个按钮外面那圈白色圆气泡。
///
/// 参数照参照图量：截图 347px 宽（对应 430pt 机型，比例 0.807；对应 393pt
/// 机型，比例 0.883），圆直径 36px ⇒ **40pt**；纯白填充；底下有一圈很淡的
/// 投影 —— 气泡正下方 1~2px 的亮度从 248 掉到 241，约 4% 黑、半径 4、下移 1，
/// 就是那点「浮起来」的感觉。
///
/// iOS 26 的液体玻璃导航栏本来就会给每个 bar item 套一圈玻璃，再画一个白圆
/// 就是圆圈套圆圈，所以那一支原样返回，什么都不加。
struct NavBubble: ViewModifier {

    /// 气泡直径。左上返回和右上「…」共用同一个数，别各写一份。
    static let diameter: CGFloat = 40

    /// 白底在深色模式下会刺眼，深色用 10% 白叠在卡片底色上。
    static var fill: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.10)
                : UIColor.white
        })
    }

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .frame(width: Self.diameter, height: Self.diameter)
                .background {
                    Circle()
                        .fill(Self.fill)
                        .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
                }
                .contentShape(Circle())
        }
    }
}

// MARK: - 左上角返回气泡

/// 气泡里那个图标：两条左端对齐、长度不等的圆头横线。
///
/// 参照图量的（气泡直径 127px = 40pt，即 3.175px/pt）：
///   · 上横线 x 77–135、y 75–80 ⇒ 宽 18.6pt、厚 2pt
///   · 下横线 x 77–115、y 101–107 ⇒ 宽 12.3pt、厚 2pt，左端和上横线对齐
///   · 两线中心距 26.5px ⇒ 8.35pt（中间缝隙 6.35pt）
///   · 上横线的水平中心正好落在圆心 ⇒ 整块居中，不是左顶格
///
/// 不用 SF Symbol：`line.3.horizontal` 是三条、`text.alignleft` 是四条，
/// 两条的现成符号没有，画两条 Capsule 反而最准。
struct NavTwoLineGlyph: View {

    private static let lineWidth: CGFloat = 18.6
    private static let shortLineWidth: CGFloat = 12.3
    private static let thickness: CGFloat = 2
    /// 两线中心距 8.35pt，扣掉两条线各半厚，就是 VStack 的间距。
    private static let gap: CGFloat = 8.35 - thickness

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            Capsule()
                .frame(width: Self.lineWidth, height: Self.thickness)
            Capsule()
                .frame(width: Self.shortLineWidth, height: Self.thickness)
        }
        .foregroundStyle(ChatColors.primaryText)
    }
}

/// 导航栏左上角的返回按钮：白圆气泡 + 两条横线的图标。
///
/// 只在 iOS 26 以下用（调用方 `AIChatView.showsCustomBackButton` 统一判定）。
/// 换掉系统返回按钮不会丢任何操作方式 —— 本项目的左边缘右滑早就被抽屉接管
/// 了（见 `ContentView+Drawer.swift` 开头那段说明：`interactivePopGesture`
/// 被显式关掉并挂了对抽屉 pan 的永久失败依赖），返回本来就只有点这个按钮
/// 一条路。
///
/// `dismiss()` 对 NavigationStack 的目标页就是 pop，和系统返回按钮走的是
/// 同一条路径，`navigationPath` 的观察者、`currentStackSessionId` 的同步
/// 一个都不少。
struct NavBackBubbleButton: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
        } label: {
            NavTwoLineGlyph()
                .modifier(NavBubble())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(AppLocalized("Back")))
    }
}

// MARK: - 右上角「…」气泡（UIKit 版）

/// iOS 16–18 的「…」气泡。
///
/// 右上角那个「…」不是 SwiftUI 视图，而是 `ChatNavMenuBarItemInstaller` 挂到
/// 导航条上的**真实 `UIBarButtonItem`**（那边的注释写了为什么非要用真 bar
/// item：系统才肯自己摆放它，且已经打开的 UIMenu 不会在流式输出时刷新）。
/// 所以这里给不了它 SwiftUI 的 `NavBubble`，只能把同样的白圆画成它的
/// `customView`。
///
/// 参数和 `NavBubble` 逐项对齐：直径 40pt、纯白（深色 10% 白）、4% 黑投影
/// 半径 4 下移 1；中间仍是原来那颗 14pt medium 的 `ellipsis`。
///
/// 视图自己不加任何手势：`UIBarButtonItem` 的点击/菜单挂在它自己的容器上，
/// 子视图不拦截触摸，照常弹出菜单。
final class NavBubbleBarItemView: UIView {

    private let icon = UIImageView()

    init(symbolName: String, pointSize: CGFloat) {
        let d = NavBubble.diameter
        super.init(frame: CGRect(x: 0, y: 0, width: d, height: d))

        backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.10)
                : UIColor.white
        }
        layer.cornerRadius = d / 2
        // 和 SwiftUI 那圈 `.shadow` 同参数：不让 masksToBounds 跟着圆角裁，
        // 否则投影一并被裁没。
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.05
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)

        icon.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        )
        icon.tintColor = UIColor(ChatColors.primaryText)
        icon.contentMode = .center
        icon.frame = bounds
        icon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: NavBubble.diameter, height: NavBubble.diameter)
    }
}

// MARK: - 导航栏第二行：小电脑 + 中转站状态点

/// 导航栏第二行的开头：一个显示器小图标，右上角一颗红/绿状态点。
///
/// [参照图对齐 2026-11-13 第二轮] 原来这里还带中转站地址的文字，用户要求
/// 标题下面**只留一行**（小电脑 + 状态点 + 供应商 · 模型名 + 思考强度），
/// 设备名/中转站地址不再显示，所以这个视图只剩图标和点，文字归到了右边
/// 那一行里。
///
/// 自己订阅 `RelayStore`（而不是让整页订阅）：toolbar 内容挂在等值门后面，
/// 开关抽屉、流式输出都不会让它重算，只有这里自己观察到状态变了才刷新。
///
/// 红绿判定只用一件事：**后台有没有拉到设备状态**（`device != nil`）。
/// 线路判定（`route`）只说明「打算走哪条线」，不说明那条线通不通；
/// 路由器 ping（`routerOnline`）探的是路由器，不是中转站本身。
struct RelayStatusIcon: View {

    @ObservedObject private var relay = RelayStore.shared

    /// 参照图里那颗绿：rgb(0, 194, 154)。
    private static let onlineColor = Color(red: 0, green: 194 / 255, blue: 154 / 255)

    private var online: Bool { relay.device != nil }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "desktopcomputer")
                // [参照图对齐 2026-11-13 第三轮] 12pt 不动。参照图逐像素量的：
                // 显示器屏幕 47×36px、同一行的文字 cap 高 34px ⇒ 图标宽是文字
                // cap 的 1.38 倍。`desktopcomputer` 在 12pt 下约 13pt 宽，配
                // 11pt 的文字（cap 7.8）是 1.67 倍 —— 比参照略大但同一档。
                // 之前配 9pt 文字时是 2.0 倍，看着才是「图标抢戏」。
                .font(.system(size: 12))
                .foregroundStyle(ChatColors.secondaryText)
            Circle()
                .fill(online ? Self.onlineColor : Color.red)
                .frame(width: 4, height: 4)
                // [参照图对齐 2026-11-13 第三轮] 上移量 2 → 1。参照里绿点只
                // 比图标顶边高 2px（整颗图标 45px 高，即 4%，换算到 12pt 图标
                // 上是半个点），我们突出去 2pt 才是「绿点压到标题」的直接原因：
                // 等于把 -4pt 的行间距又吃掉 2pt。压到 1pt 后它只探头一点点，
                // 和参照一样半挂在线框上。
                .offset(x: 2, y: -1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("中转站"))
        .accessibilityValue(Text(online ? AppLocalized("Connected") : AppLocalized("Disconnected")))
    }
}


// MARK: - 吃掉导航栏底边的分隔线

/// 把 `UINavigationBar` 底边那条 1px 分隔线清掉。
///
/// 为什么非要用 UIKit：SwiftUI 只提供 `.toolbarBackground(...)`，它管的是
/// 底色，那条线是 `UINavigationBarAppearance.shadowColor` 画出来的 —— 没有
/// 对应的 SwiftUI API。
///
/// 为什么这次要清：卡片和导航栏的底色是同一个颜色（都是
/// `ChatColors.background`），系统还按「有背景色 = 需要一条分界」的老规矩
/// 画一条深灰，结果卡片被横切成上下两截，像多了一道边框。
///
/// 实现：挂一个零尺寸的宿主 VC，在布局时找到自己所在的
/// `UINavigationController`，把三份 appearance 的 `shadowColor` 都改成透明。
/// 每次布局都确认一次 —— SwiftUI 每推一次工具栏就会重新写一遍 appearance，
/// 只设一次会被它盖回去；已经透明就直接返回，不会来回打架。
private struct NavBarSeparatorRemover: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> Probe { Probe() }

    func updateUIViewController(_ vc: Probe, context: Context) {
        vc.removeSeparator()
    }

    /// 只用来摸到父级导航栏，不画任何东西。
    final class Probe: UIViewController {

        /// viewDidAppear 之后补清一次：SwiftUI 的工具栏桥接会把 appearance
        /// 再写一遍，那次写入可能落在我们上一次布局之后。
        private var didCatchLatePush = false

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            removeSeparator()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            removeSeparator()
            // 只补一次，不递归：清干净之后再调是空操作，没必要长期挂着
            // async 在主队列上反复触发。
            guard !didCatchLatePush else { return }
            didCatchLatePush = true
            DispatchQueue.main.async { [weak self] in self?.removeSeparator() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            removeSeparator()
        }

        func removeSeparator() {
            guard let nav = enclosingNavigationController else { return }
            let bar = nav.navigationBar

            // ① 页面级（关键）：SwiftUI 的 `.toolbarBackground(_:for:)` 是把颜色
            //    写进**导航项自己**的 appearance，而导航项上的优先级高于 bar 上
            //    的默认值。上一版只清了 bar 那份，所以线一直在 —— 实测截图
            //    y=80px 处那条 rgb(233,233,233) 就是它。
            for item in Self.appearanceItems(of: nav) {
                if let a = Self.cleared(item.standardAppearance) { item.standardAppearance = a }
                if let a = Self.cleared(item.scrollEdgeAppearance) { item.scrollEdgeAppearance = a }
                if let a = Self.cleared(item.compactAppearance) { item.compactAppearance = a }
            }

            // ② bar 级：导航项没有自带 appearance 时才用这份默认值。
            if let a = Self.cleared(bar.standardAppearance) { bar.standardAppearance = a }
            if let a = Self.cleared(bar.scrollEdgeAppearance) { bar.scrollEdgeAppearance = a }
            if let a = Self.cleared(bar.compactAppearance) { bar.compactAppearance = a }

            // ③ 老 API 兜底：iOS 13 之前这条线是 `shadowImage` 画的，有些系统
            //    版本在 appearance 清空后仍会回落到它，给一张空图。
            if bar.shadowImage == nil { bar.shadowImage = UIImage() }
        }

        /// 把一份 appearance 的 `shadowColor` 清成透明。
        ///
        /// 已经是透明、或者压根没有这份 appearance 就返回 nil，调用方据此跳过
        /// 赋值 —— 避免每次布局都往 UIKit 里灌一遍新对象。
        ///
        /// 必须 copy 出新实例再赋回去：`UIBarAppearance` 是引用类型，原地改完
        /// 再赋同一个对象，UIKit 有可能认为「没变化」而不重画。
        private static func cleared(_ appearance: UINavigationBarAppearance?) -> UINavigationBarAppearance? {
            guard let appearance, appearance.shadowColor != .clear else { return nil }
            let copy = (appearance.copy() as? UINavigationBarAppearance) ?? appearance
            copy.shadowColor = .clear
            return copy
        }

        /// 当前页 + 可见页的导航项。两个都过：push/pop 动画中间它们可能不是
        /// 同一个 VC。
        private static func appearanceItems(of nav: UINavigationController) -> [UINavigationItem] {
            var items: [UINavigationItem] = []
            for vc in [nav.topViewController, nav.visibleViewController].compactMap({ $0 }) {
                if !items.contains(where: { $0 === vc.navigationItem }) {
                    items.append(vc.navigationItem)
                }
            }
            return items
        }

        /// 找到自己挂着的那个导航控制器。
        ///
        /// 三条路依次试：VC 关系 → 响应链 → 从 window 根 VC 递归找主栈。
        ///
        /// 最后一条是保底，也是这个文件里最实用的一条：SwiftUI 给
        /// representable 套的宿主 VC 有时既不认 `navigationController`，
        /// 响应链上也摸不到（抽屉那边 `InteractivePopGestureDisabler` 就是
        /// 这么静默失败一整版的）。视图一定在某个 window 里，从根 VC 往下
        /// 递归 `children` 一定能摸到 —— 抽屉手势层用的就是这个办法。
        private var enclosingNavigationController: UINavigationController? {
            if let nav = navigationController ?? parent?.navigationController {
                return nav
            }
            var r: UIResponder? = view
            var hops = 0
            while let cur = r, hops < 32 {
                if let nav = cur as? UINavigationController {
                    return nav
                }
                if let vc = cur as? UIViewController, let nav = vc.navigationController {
                    return nav
                }
                r = cur.next
                hops += 1
            }
            guard let root = view.window?.rootViewController else { return nil }
            return Self.nearestNavigationController(in: root)
        }

        /// 只在 `children` 里递归，不走 `presentedViewController`：设置页那类是
        /// sheet，自带一套导航栈，动它会把人家自己的返回线也摘掉。
        private static func nearestNavigationController(in vc: UIViewController) -> UINavigationController? {
            if let nav = vc as? UINavigationController { return nav }
            for child in vc.children {
                if let nav = nearestNavigationController(in: child) { return nav }
            }
            return nil
        }
    }
}

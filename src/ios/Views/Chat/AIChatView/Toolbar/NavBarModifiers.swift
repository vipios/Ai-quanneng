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

/// 导航栏左上角的返回按钮：白圆气泡 + `chevron.left`。
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
            Image(systemName: "chevron.left")
                // 参照里箭头的大写高度和内文标题接近，17pt semibold 落在
                // 40pt 圆里上下左右都留白均匀。
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ChatColors.primaryText)
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
                // 参照里图标 13×12px ⇒ 15×14pt，`desktopcomputer` 在 12pt
                // 渲染出来正好这个尺寸。
                .font(.system(size: 12))
                .foregroundStyle(ChatColors.secondaryText)
            Circle()
                .fill(online ? Self.onlineColor : Color.red)
                .frame(width: 4, height: 4)
                // 压在显示器右上角外侧，和参照一样半挂在线框上。
                .offset(x: 3, y: -2)
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

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            removeSeparator()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            removeSeparator()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            removeSeparator()
        }

        func removeSeparator() {
            guard let bar = enclosingNavigationBar else { return }

            // 三份都要过：standard 管常态，scrollEdge 管列表贴顶，compact 管
            // 横屏等窄高度。少一份就会在某个状态下把线漏出来。
            //
            // 用 copy() 造新实例再赋回去，而不是原地改：`UIBarAppearance` 是
            // 引用类型，原地改完再赋同一个对象，UINavigationBar 有可能认为
            // 「没变化」不刷新。
            if bar.standardAppearance.shadowColor != .clear {
                let a = (bar.standardAppearance.copy() as? UINavigationBarAppearance)
                    ?? bar.standardAppearance
                a.shadowColor = .clear
                bar.standardAppearance = a
            }
            if let scroll = bar.scrollEdgeAppearance, scroll.shadowColor != .clear {
                let a = (scroll.copy() as? UINavigationBarAppearance) ?? scroll
                a.shadowColor = .clear
                bar.scrollEdgeAppearance = a
            }
            if let compact = bar.compactAppearance, compact.shadowColor != .clear {
                let a = (compact.copy() as? UINavigationBarAppearance) ?? compact
                a.shadowColor = .clear
                bar.compactAppearance = a
            }
        }

        /// 找到自己挂着的那个导航栏。
        ///
        /// 先走 VC 关系（SwiftUI 把 representable 的 VC 挂在宿主 VC 下面），
        /// 拿不到再沿响应链往上摸一遍 —— 不同 iOS 版本里 SwiftUI 的容器层级
        /// 不一样，只认 `navigationController` 有摸空的时候。
        private var enclosingNavigationBar: UINavigationBar? {
            if let nav = navigationController ?? parent?.navigationController {
                return nav.navigationBar
            }
            var r: UIResponder? = view
            var hops = 0
            while let cur = r, hops < 32 {
                if let nav = cur as? UINavigationController {
                    return nav.navigationBar
                }
                if let vc = cur as? UIViewController, let nav = vc.navigationController {
                    return nav.navigationBar
                }
                r = cur.next
                hops += 1
            }
            return nil
        }
    }
}

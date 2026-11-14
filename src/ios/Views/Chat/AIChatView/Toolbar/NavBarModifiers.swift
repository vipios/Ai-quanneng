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
        // [2026-11-14 第二十轮] 导航带 + 下沿那条过渡。两个分支都要挂。
        //
        // 上一版把它写在 iOS 16–18 那一支里、位置又用 `topSafeAreaInset` 算，
        // 实机一点效果都没有：那个值在这棵树上恒为 0，渐变被画到了 51.67pt
        // （状态栏里），颜色又和底色一样，等于没画。
        //
        // 这一版不再要那个值：从屏幕最顶上铺下来，0 → 108 全实色，
        // 108 → 123 按参照实测的曲线落到底。带子自己有没有底色都不影响。
        .overlay(alignment: .top) {
            TopBandFade()
        }
        // 导航栏底边那条 1px 分隔线，两个分支都要摘。
        .background {
            NavBarSeparatorRemover()
                .frame(width: 0, height: 0)
        }
    }
}

// MARK: - 导航带 + 下沿的过渡

/// 从屏幕顶上铺下来的一条：0 → 108 实色，108 → 123 淡出。
///
/// 和输入栏那条（`AIChatView+InputBar.swift:504`）是同一个办法，只是方向反过来：
/// 输入栏是「透明 → 实色」压在底部，让内容不从底下漏出来；这条是「实色 → 透明」
/// 压在上面，让内容往上滑时淡出去。
///
/// **为什么从 0 铺起**：导航带自己的底色不可靠 —— 实机截图量下来，带子区域
/// 的像素和页面底色一模一样（都是 248），内容在 98.67pt 就已经完整露出来了，
/// 带子等于没盖住东西。所以这条渐变干脆把整段都自己铺：0 → 108 实色，
/// 顺带把带子没盖住的那段也盖上；108 → 123 才是过渡。
///
/// 中间那几个停靠点不是均分的，是拿参照截图逐行量出来的实际透明度：
///
///   108.00 → 内容透出  2%   ⇒ 盖 0.98
///   110.67 → 内容透出  8%   ⇒ 盖 0.92
///   117.33 → 内容透出 25%   ⇒ 盖 0.75
///   121.33 → 内容透出 77%   ⇒ 盖 0.23
///   122.67 → 内容透出 95%   ⇒ 盖 0.05
///   123.00 → 内容全亮       ⇒ 盖 0
///
/// 也就是前 9.3pt 几乎不动（一直压到 0.98…0.75），最后 5.7pt 才猛落到底。
///
/// 位置直接用点数摆，只在本页自己的范围里画、**不越界**：先读这一层顶边
/// 在屏幕上的位置，`108 − 顶边` 就是实色段该铺多高，剩下 15 就是
/// 过渡带。页面顶边落在 0 / 59 / 103 哪一处，最后都落到同一条线上。
///
/// **不用 `ignoresSafeArea()`**：那会让这一层撑满整屏、连导航栏那块一起
/// 盖住，右上「…」和左上返回的点击就被吃掉了（1.66 实机验证过一次）。
/// 现在它严格待在页面自己的 bounds 里，碰不到导航栏里的任何按钮。
struct TopBandFade: View {

    /// 状态栏下沿。15 Pro Max = 59；拿不到就用这个兜底。
    static let statusBarHeight: CGFloat = 59

    /// 带子实色段高度。51.67 → 49：下沿从 110.67 收到 108，和参照同一条线。
    static let bandHeightBelowSafeArea: CGFloat = 49

    /// 过渡带高度。108 → 123，15.0pt，和参照一样宽。
    static let fadeHeight: CGFloat = 15

    /// 实色段的绝对下沿（屏幕坐标）。
    static var bandBottom: CGFloat { statusBarHeight + bandHeightBelowSafeArea }

    var body: some View {
        GeometryReader { geo in
            // 这一层顶边在屏幕上的位置。恒为 0 的是 `safeAreaInsets`，不是这个。
            let top = geo.frame(in: .global).minY
            // 实色段：从这一层顶边铺到屏幕 108 那条线。
            // 页面顶边已经在 108 时，这个数是 0，就只画过渡带。
            let solid = max(0, Self.bandBottom - top)
            VStack(spacing: 0) {
                if solid > 0.5 {
                    ChatColors.background
                        .frame(height: solid)
                }
                // 过渡带：108 → 123，15pt
                LinearGradient(
                    stops: [
                        .init(color: ChatColors.background.opacity(0.98), location: 0),
                        .init(color: ChatColors.background.opacity(0.92), location: 0.178),
                        .init(color: ChatColors.background.opacity(0.75), location: 0.622),
                        .init(color: ChatColors.background.opacity(0.23), location: 0.889),
                        .init(color: ChatColors.background.opacity(0.05), location: 0.978),
                        .init(color: ChatColors.background.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: Self.fadeHeight)
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, alignment: .top)
        }
        // 不加 `ignoresSafeArea()`：那会伸到导航栏上，吃掉右上「…」的点击。
        .allowsHitTesting(false)
    }
}

// MARK: - 导航栏圆形气泡

/// 导航栏左右两个按钮外面那圈白色圆气泡。
///
/// 参数照参照图量：同机型全屏截图（1290px 宽 / 430pt，3.0 px/pt）上圆直径
/// 132px ⇒ **44pt**；左边距卡片 16.00pt、顶边 67.00pt；纯白填充；底下有一圈
/// 很淡的投影 —— 约 5% 黑、半径 4、下移 1，就是那点「浮起来」的感觉。
///
/// iOS 26 的液体玻璃导航栏本来就会给每个 bar item 套一圈玻璃，再画一个白圆
/// 就是圆圈套圆圈，所以那一支原样返回，什么都不加。
struct NavBubble: ViewModifier {

    /// 气泡直径。左上返回和右上「…」共用同一个数，别各写一份。
    ///
    /// [2026-11-14 第九轮] 40 → 44。参照同机型全屏截图逐像素量的：气泡
    /// bbox 132px = **44pt**，左边距卡片 16.00pt（这条我们本来就是 16.00，
    /// 一分不差），顶边 67.00pt。我们原来 40pt，比参照小一圈。
    static let diameter: CGFloat = 44

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
        // [参照图对齐 2026-11-13 第七轮] 改成「图标定尺寸 + overlay 贴点」。
        //
        // 原来是一个 ZStack(alignment: .topTrailing)，绿点按图标的**布局框**
        // 右上角对齐。问题是 SF Symbol 的布局宽度比墨迹宽一大截（12pt 的
        // `desktopcomputer` 墨迹约 17.7pt，布局框还要再宽一圈），绿点于是被
        // 推到墨迹右侧之外 —— 实测就在 x 94..97.7，看着像浮在「中」字上面
        // 的一颗绿点，而不是挂在显示器右上角。参照图里绿点右边缘正好和图标
        // 墨迹右边缘齐平（83.04 / 83.04）。
        //
        // 先把图标收紧到墨迹尺寸，overlay 的 .topTrailing 才真的是墨迹角。
        // 12 × 10 是第七轮那版的实测值，第九轮按参照重算成 14.7 × 12.5。
        Image(systemName: "desktopcomputer")
            // [2026-11-14 第九轮] 12 → 10pt，frame 12×10 → 14.7×12.5，按参照
            // 逐像素重定：参照这一坨（图标+绿点）bbox 是 x 76.67..91.00、高
            // 14.00，宽 **14.33**；我们原来 12pt 跑出来 17.67 宽，比参照胖
            // 3.3pt，右边缘被顶到 83.67，把后面的文字整体推右、间距只剩 4.34。
            //
            // 10pt × (17.67 ÷ 12) = 14.73，正好落在参照的 14.33~14.67 上；
            // 高度 15.00 × 10/12 = 12.5（比参照矮 1.5，SF Symbol 的长宽比改
            // 不了，宽度对上了才是关键 —— 右边缘决定了后面文字的起点）。
            // frame 取 14.7×12.5 让墨迹刚好填满，overlay 的 .topTrailing 才
            // 真的是墨迹角，绿点不用再额外补偏移。
            .font(.system(size: 10))
            .foregroundStyle(ChatColors.secondaryText)
            .frame(width: 14.7, height: 12.5)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(online ? Self.onlineColor : Color.red)
                    // 参照逐像素量的：绿点直径 3.3pt（bbox 3.55 × 3.11），
                    // 右边缘和图标墨迹右边缘齐平，顶边只比图标顶边低 0.4pt。
                    // 原来是 4pt、还往外甩 2pt，既大又飘。
                    .frame(width: 3.3, height: 3.3)
                    .offset(x: -0.2, y: 0.5)
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
        vc.syncChrome()
    }

    /// 只用来摸到父级导航栏，不画任何东西。
    final class Probe: UIViewController {

        /// viewDidAppear 之后补清一次：SwiftUI 的工具栏桥接会把 appearance
        /// 再写一遍，那次写入可能落在我们上一次布局之后。
        private var didCatchLatePush = false

        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            // 越早越好。这时候可能还没接上导航栈，拿不到就跳过；
            // 不主动触发 view 加载（`isViewLoaded` 拦一下），免得打乱布局。
            if isViewLoaded { syncChrome() }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            syncChrome()
        }

        override func viewWillLayoutSubviews() {
            super.viewWillLayoutSubviews()
            // 比 `viewDidLayoutSubviews` 早一步。
            //
            // 那一版只在 did 里同步，而 did 是**布局结束**才调 —— 那时这一帧
            // 已经定稿，改完得等下一帧才画出来。用户看到的就是：进页面先闪
            // 一下「内容被切在 97.33」的旧样子，然后才跳成带子抬到 108 的
            // 样子。挪到 will 里，同一次布局就把带子改好，画出来就是对的。
            syncChrome()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            syncChrome()
            // 只补一次，不递归：清干净之后再调是空操作，没必要长期挂着
            // async 在主队列上反复触发。
            guard !didCatchLatePush else { return }
            didCatchLatePush = true
            DispatchQueue.main.async { [weak self] in self?.syncChrome() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            syncChrome()
        }

        /// 两件事：放开裁剪、摘掉底边分隔线。带子的实色段不再靠拉高背景层，
        /// 改由 `TopBandFade` 自己铺（它从屏幕顶铺实色到 108），所以这里
        /// 不再动 `backgroundLayer` 的 frame —— 那件事是「进页面闪一下原版」
        /// 的根源（事后改 frame，第一帧总是旧高度）。
        func syncChrome() {
            guard let nav = enclosingNavigationController else { return }
            let bar = nav.navigationBar
            openClips(on: bar)
            removeSeparator()
        }

        func removeSeparator() {
            guard let nav = enclosingNavigationController else { return }
            let bar = nav.navigationBar
            let color = UIColor(ChatColors.background).resolvedColor(with: bar.traitCollection)

            // ① 页面级（关键）：SwiftUI 的 `.toolbarBackground(_:for:)` 是把颜色
            //    写进**导航项自己**的 appearance，而导航项上的优先级高于 bar 上
            //    的默认值。上一版只清了 bar 那份，所以线一直在 —— 实测截图
            //    y=80px 处那条 rgb(233,233,233) 就是它。
            for item in Self.appearanceItems(of: nav) {
                if let a = Self.styled(item.standardAppearance, fadingColor: color) { item.standardAppearance = a }
                if let a = Self.styled(item.scrollEdgeAppearance, fadingColor: color) { item.scrollEdgeAppearance = a }
                if let a = Self.styled(item.compactAppearance, fadingColor: color) { item.compactAppearance = a }
            }

            // ② bar 级：导航项没有自带 appearance 时才用这份默认值。
            if let a = Self.styled(bar.standardAppearance, fadingColor: color) { bar.standardAppearance = a }
            if let a = Self.styled(bar.scrollEdgeAppearance, fadingColor: color) { bar.scrollEdgeAppearance = a }
            if let a = Self.styled(bar.compactAppearance, fadingColor: color) { bar.compactAppearance = a }

            // ③ 老 API 兜底：iOS 13 之前这条线是 `shadowImage` 画的，有些系统
            //    版本在 appearance 清空后仍会回落到它，给一张空图。
            if bar.shadowImage == nil { bar.shadowImage = UIImage() }
        }

        // MARK: - 放开裁剪

        /// [2026-11-14 第十一轮] 关掉导航栏对子视图的裁剪。
        ///
        /// 起因：用户报「我们的字体和左上右上图标被裁」。
        ///
        /// 截图逐像素量的（1290px / 430pt，3.0 px/pt）：左右两个 44pt 气泡
        /// 顶边都在 **67.00pt**，和参照一分不差 —— 位置本来就是对的。但可见
        /// 高度只有 30.67pt，底边被一条水平线硬切在 **97.33pt**；第二行文字
        /// 墨迹顶 94.00、高 14.33，也只露出 3.67pt。参照在同样的位置上能完整
        /// 露到 110.67pt。
        ///
        /// 所以这里只改一个已有的属性：把 bar 和它内部各层容器的
        /// `clipsToBounds` 设回 false，让已经摆好的内容画出来。一个 frame、
        /// 一个 offset 都不动，位置因此不会变。
        ///
        /// 为什么连子视图一起放开：真正在裁的是 bar 内部那个内容容器
        /// （`_UINavigationBarContentView` 一类），只放开 bar 自己这层不够。
        /// 深度限 4 层：bar → contentView → 内容栈 → 具体 item，够到了就停，
        /// 再往下是系统内部的东西，不碰。
        private func openClips(on bar: UINavigationBar) {
            if bar.clipsToBounds { bar.clipsToBounds = false }
            Self.openClips(in: bar, depth: 0)
        }

        private static func openClips(in view: UIView, depth: Int) {
            guard depth < 4 else { return }
            for sub in view.subviews {
                if sub.clipsToBounds { sub.clipsToBounds = false }
                openClips(in: sub, depth: depth + 1)
            }
        }

        /// 把一份 appearance 改成「摘掉分隔线 + 实色背景」。
        ///
        /// [2026-11-14 第十七轮] 底部那条渐隐**已整段退回**，不再往 appearance
        /// 里塞任何背景图 —— 塞进去的图会被系统按它自己的尺寸重画，位置对不上，
        /// 实机看不出过渡效果。带子这里只负责「实色铺到 108」这一件事。
        ///
        /// 已经是目标状态就返回 nil，调用方据此跳过赋值 —— 避免每次布局都往
        /// UIKit 里灌一遍新对象（每次赋值都会重画整条 bar）。
        ///
        /// 必须 copy 出新实例再赋回去：`UIBarAppearance` 是引用类型，原地改完
        /// 再赋同一个对象，UIKit 有可能认为「没变化」而不重画。
        private static func styled(_ appearance: UINavigationBarAppearance?,
                                   fadingColor color: UIColor) -> UINavigationBarAppearance? {
            guard let appearance else { return nil }
            // 已经是我们写的那一份、且配色没变：不重复赋值（每次赋值都重画整条 bar）。
            if appearance.shadowColor == .clear,
               appearance.backgroundColor == color,
               appearance.backgroundEffect == nil,
               appearance.backgroundImage == nil {
                return nil
            }
            let copy = (appearance.copy() as? UINavigationBarAppearance) ?? appearance
            copy.shadowColor = .clear
            // 实色铺满整条带子，到 108 为止。
            copy.backgroundColor = color
            // 毛玻璃关掉，免得它把带子下面的内容虚化出第二层效果。
            copy.backgroundEffect = nil
            copy.backgroundImage = nil
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

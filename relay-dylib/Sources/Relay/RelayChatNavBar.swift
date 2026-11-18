//
//  RelayChatNavBar.swift
//  RelayDylib — 聊天页顶部导航条（照 fork 的聊天页 1:1 复刻）
//
//  为什么是「画一条」而不是「替换 App 的导航条」：
//    fork 那套精致导航条（导航带 + 过渡带 + 两行标题 + 白色圆气泡）是写在
//    App 源码里的，依赖 ChatColors / RelayStore.shared / drawerOpen 这些
//    fork 专属的内部类型。dylib 是独立 module，编译期拿不到它们，没法
//    hook 进去替换官方的原生导航条。
//
//    所以做法是在我们自己的浮层窗口顶部「盖」一条同款导航条：视觉上和 fork
//    聊天页一致，左上角的圆气泡点开我们自己的管理抽屉。官方原生导航条被压在
//    下面（浮层 windowLevel = .alert+1），视觉上看不见；原生返回/… 仍在，
//    但顶部这一条区域的触摸归我们 —— 这正是「替换左上角图标」要达到的效果。
//
//  照搬的参照（src/ios/Views/Chat/AIChatView/Toolbar/NavBarModifiers.swift）：
//    · TopBandFade      实色到 108，过渡带 108→123（15pt）
//    · NavBubble        直径 44pt，白圆 / 深色 10% 白，5% 黑投影
//    · NavTwoLineGlyph  上横线 18.6 / 下横线 12.3 / 厚 2 / 中心距 8.35
//    · 主标题           16pt semibold
//    · 副标题           12pt secondaryLabel，行首 desktopcomputer + 绿点
//    · ChatColors.background 浅色 #f8f8f8
//
//  副标题文字没有照搬 fork 的「provider · model · 思考等级」——那些是 App
//  内部状态，dylib 拿不到。这里换成 dylib 自己能拿到的真实信息：当前线路
//  （内网/外网）+ 中转站是否在线。排版、字号、颜色完全一致。
//

import SwiftUI
import UIKit

// MARK: - 导航栏配色（照搬 ChatColors 里用到的几支）

private enum NavPalette {
    /// ChatColors.background：浅色 #f8f8f8，深色 systemBackground。
    static var background: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? .systemBackground
                : UIColor(red: 0xf8 / 255, green: 0xf8 / 255, blue: 0xf8 / 255, alpha: 1)
        })
    }
    static var primaryText: Color { Color(UIColor.label) }
    static var secondaryText: Color { Color(UIColor.secondaryLabel) }
    /// 圆气泡：浅色纯白，深色 10% 白。
    static var bubbleFill: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.10)
                : .white
        })
    }
    /// RelayStatusIcon 里量到的绿 rgb(0,194,154)。
    static let onlineGreen = Color(red: 0, green: 194 / 255, blue: 154 / 255)
}

// MARK: - 重叠挂到浮层根视图的导航条容器

/// 用 UIHostingController 承载 SwiftUI 导航条，addChild 到浮层的
/// RelayOverlayViewController，这样导航条跟着浮层窗口走，App 任何界面都在。
final class RelayChatNavBarHost: UIViewController {

    private var host: UIHostingController<RelayChatNavBarView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let h = UIHostingController(rootView: RelayChatNavBarView())
        h.view.backgroundColor = .clear
        addChild(h)
        view.addSubview(h.view)
        h.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            h.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            h.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            h.view.topAnchor.constraint(equalTo: view.topAnchor),
            h.view.heightAnchor.constraint(equalToConstant: RelayChatNavBarMetrics.totalHeight),
        ])
        h.didMove(toParent: self)
        host = h
    }
}

/// 导航条几何常量，浮层 hitTest 也要用，集中放这里避免两处写死。
enum RelayChatNavBarMetrics {
    /// 状态栏高度（15 Pro Max = 59）。
    static let statusBar: CGFloat = 59
    /// 实色段：从顶部铺到 59 + 49 = 108。
    static let bandBelowSafeArea: CGFloat = 49
    /// 过渡带：108 → 123，15pt。
    static let fade: CGFloat = 15
    /// 导航条占的总高度（屏幕坐标）：108 + 15。
    static let totalHeight: CGFloat = statusBar + bandBelowSafeArea + fade

    /// 左上角气泡直径。
    static let bubbleDiameter: CGFloat = 44
    /// 左上角气泡的可点区域：x 从 8 到 8+44=52，y 从 59 到 59+44=103。
    /// 比 fork 的 15.3 略靠左一点，给拇指好按，视觉仍在导航带内。
    static let leftBubbleFrame = CGRect(x: 8, y: statusBar + 6, width: bubbleDiameter, height: bubbleDiameter)
}

// MARK: - 导航条本体

struct RelayChatNavBarView: View {

    @ObservedObject private var relay = RelayStore.shared

    var body: some View {
        GeometryReader { geo in
            let top = geo.frame(in: .global).minY
            // 浮层窗口通常是全屏，top = 0；兜底按屏幕顶部算。
            let solid = max(0, RelayChatNavBarMetrics.statusBar + RelayChatNavBarMetrics.bandBelowSafeArea - top)

            VStack(spacing: 0) {
                // ── 实色导航带：顶部到 108 ──
                NavPalette.background
                    .frame(height: solid)

                // ── 过渡带：108 → 123，磨砂 + 压淡，照 TopBandFade ──
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(.regularMaterial)
                        .mask(Rectangle().fill(Self.blurMask))
                    LinearGradient(
                        stops: [
                            .init(color: NavPalette.background.opacity(0.98), location: 0),
                            .init(color: NavPalette.background.opacity(0.92), location: 0.178),
                            .init(color: NavPalette.background.opacity(0.75), location: 0.622),
                            .init(color: NavPalette.background.opacity(0.23), location: 0.889),
                            .init(color: NavPalette.background.opacity(0.05), location: 0.978),
                            .init(color: NavPalette.background.opacity(0), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(height: RelayChatNavBarMetrics.fade)

                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, alignment: .top)
            // 导航带本身不吃触摸：只有左上角气泡和标题区吃，其余穿透给 App。
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                leftBubble
            }
            .overlay(alignment: .top) {
                // 标题从左上角气泡右侧起（气泡 x=8~52），右侧给 ⋯ 留位。
                titleStack
                    .padding(.leading, 60)
                    .padding(.trailing, 60)
                    .padding(.top, RelayChatNavBarMetrics.statusBar - 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: RelayChatNavBarMetrics.totalHeight)
    }

    // ── 左上角：白圆气泡 + 两横线（照 NavBubble / NavTwoLineGlyph）──
    private var leftBubble: some View {
        Button {
            RelayDrawer.shared.open()
        } label: {
            TwoLineGlyph()
                .frame(width: RelayChatNavBarMetrics.bubbleDiameter,
                       height: RelayChatNavBarMetrics.bubbleDiameter)
                .background {
                    Circle()
                        .fill(NavPalette.bubbleFill)
                        .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: RelayChatNavBarMetrics.bubbleDiameter,
               height: RelayChatNavBarMetrics.bubbleDiameter)
        .padding(.leading, 8)
        .padding(.top, RelayChatNavBarMetrics.statusBar + 6)
        .accessibilityLabel("打开中转站管理")
    }

    // ── 两行标题：主标题 16pt semibold；副标题 12pt，行首小电脑+状态点 ──
    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("中转站")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NavPalette.primaryText)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                StatusGlyph(online: relay.device != nil)
                    .padding(.bottom, 1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(NavPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 副标题：线路 + 在线状态。都是 RelayStore 里实时刷新的真值。
    private var subtitle: String {
        let line = relay.route?.stateText ?? "线路判定中"
        let net = relay.device != nil ? "在线" : "离线"
        return "中转站 · \(line) · \(net)"
    }

    /// 照 TopBandFade.blurMask。
    private static var blurMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.95), location: 0.178),
                .init(color: .black.opacity(0.45), location: 0.622),
                .init(color: .black.opacity(0.12), location: 0.889),
                .init(color: .black.opacity(0.03), location: 0.978),
                .init(color: .black.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - 两横线图标（照 NavTwoLineGlyph 的量测）

private struct TwoLineGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8.35 - 2) {
            Capsule().frame(width: 18.6, height: 2)
            Capsule().frame(width: 12.3, height: 2)
        }
        .foregroundStyle(NavPalette.primaryText)
    }
}

// MARK: - 小电脑 + 状态点（照 RelayStatusIcon）

private struct StatusGlyph: View {
    let online: Bool
    var body: some View {
        Image(systemName: "desktopcomputer")
            .font(.system(size: 10))
            .foregroundStyle(NavPalette.secondaryText)
            .frame(width: 14.7, height: 12.5)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(online ? NavPalette.onlineGreen : Color.red)
                    .frame(width: 3.3, height: 3.3)
                    .offset(x: -0.2, y: 0.5)
            }
    }
}

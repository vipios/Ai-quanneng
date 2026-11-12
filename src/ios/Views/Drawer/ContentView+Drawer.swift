//
//  ContentView+Drawer.swift
//  全能AI - 把抽屉接进 iPhone 的 stackLayout
//
//  ============================================================
//  这里做三件事
//  ------------------------------------------------------------
//    1. 把 iPhone 的 `stackLayout` 包进 `DrawerContainer`
//    2. 给 `SessionDrawer` 备好它要的数据（会话、产物、搜索命中）
//    3. 关掉 `NavigationStack` 的系统返回手势，让左边缘右滑归抽屉
//
//  刻意不做的事
//  ------------------------------------------------------------
//    - 不改 `stackLayout` 本身：`NavigationStack`、`sessionList`、
//      `navigationDestination`、`AIChatView` 全是原版，一行没动。
//      这里只是在它外面套一层。根视图仍然是原版列表页。
//    - 不改 iPad 的 `splitLayout`：那边本来就有常驻侧栏，不需要抽屉。
//    - 不引进 `Views/Drawer/` 之外的东西（模板那套 WKWebView 方案已在
//      定制仓里被撤掉，是死代码，这里不搬）。
//
//  ============================================================
//  左滑手势的归属（这次改动的核心）
//  ------------------------------------------------------------
//  原版：对话页从屏幕左边缘右滑 → NavigationStack 的
//        interactivePopGestureRecognizer → 返回列表页
//
//  现在：同一条边缘、同一方向 → 拉开抽屉
//
//  做法是 `InteractivePopGestureDisabler`：一个零尺寸的
//  `UIViewRepresentable`，沿响应链找到 `UINavigationController`，
//  把 `interactivePopGestureRecognizer.isEnabled` 置 false。
//
//  为什么这样比「两个手势共存、靠速度/位移区分」可靠：
//  两者的起手区域完全重叠（都是屏幕左边缘），任何阈值都会在某一档
//  手感下失灵。定死归属，只有一种结果。
//
//  代价：返回键改成只能点导航栏左上角 `‹`。那个按钮是系统原生的，
//  热区、动画、无障碍全部保持原样 —— 抽屉手势层还专门在导航栏
//  那 44pt 让了位（见 EdgeDrawer 的 padding(.top)），所以按钮
//  四周都能按，不是「只有一个小点」。
//

import SwiftUI
import UIKit

extension ContentView {

    // MARK: - iPhone 主布局（原版对话 + 抽屉）

    /// 宽度由调用方从**外层**的 GeometryReader 传进来。
    ///
    /// 这里刻意不再套一层 GeometryReader —— 外层 `body` 已经是
    /// `GeometryReader { geo in ... }`，再嵌一层的话内层读到的是「建议尺寸」
    /// 而不是分配尺寸，里面的 NavigationStack 会塌成 0 高（对话页整屏空白）。
    ///
    /// 安全区也不再从 `geo.safeAreaInsets` 往下传：那个值在这棵树上可能是 0，
    /// 传下去等于把卡片出血的开关关掉（R78 就是这么静默失效的）。
    /// 现在由 `DrawerContainer` 直接问窗口要，见 `windowMetrics()`。
    func stackLayoutWithDrawer(width: CGFloat) -> some View {
        DrawerContainer(width: width) {
            SessionDrawer(
                sessions: sessions,
                folders: folders,
                groups: groupedSessionIDs(filteredSessions),
                // 抽屉高亮哪一行 = 屏幕上正在看的那个会话。
                // iPhone 走导航栈（currentStackSessionId），iPad 走
                // selectedSessionId，两个都可能是「当前」，取先有值的那个。
                currentSessionId: currentStackSessionId ?? selectedSessionId,
                artifactStore: ArtifactStore.shared,
                isActive: { sid in sessionIsRunning(sid) },
                isSuspended: { sid in sidebarConcurrencyManager.isSuspended(sid) },
                query: $drawerQuery,
                // 抽屉的搜索是独立的（drawerQuery），不要和侧栏那个
                // searchText 混用 —— 抽屉收起时侧栏搜索框仍然挂着，
                // 混用会让抽屉一打开就带着上次的搜索词。
                isSearching: drawerIsSearching,
                sessionMatches: drawerSessionMatches,
                artifactMatches: drawerArtifactMatches,
                menuActions: menuActions,
                onNewChat: { handleNewChatRequest() },
                onOpenSettings: { activeToolSheet = .settings },
                onSearchChanged: { q in drawerQuery = q }
            )
            // [R80] 这里原来还有一句 `.environmentObject(drawerState)`：
            // 抽屉现在不订阅 DrawerState 了（靠 `DrawerCloseAction` 收自己），
            // 容器顶层已经把 state 注进环境，这里再注一遍只会让抽屉
            // 重新变成订阅者 —— 一订阅，拖动过程中每帧都要重算整棵抽屉。
        } content: {
            stackLayout
                // 系统返回手势让位给抽屉。
                //
                // 放在 content 里而不是 DrawerContainer 外面，是因为
                // 它必须挂在 NavigationStack **内部**才能沿响应链
                // 找到那个 UINavigationController。
                .background(InteractivePopGestureDisabler())
        }
    }

    // MARK: - 抽屉搜索的匹配结果
    //
    // 抽屉是原版 SwiftUI 之后，搜索也得自己算。
    //
    // 口径刻意和原版侧栏一致：会话按标题匹配、产物按文件名匹配，
    // 命中处不高亮片段（`matchSnippet` 传 nil）。原版侧栏那套高亮是给
    // `List` 的 AttributedString 用的，抽屉里行结构不同，硬套会错位。

    /// 抽屉搜索是否生效。
    var drawerIsSearching: Bool {
        !drawerQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 命中的会话 id → 匹配到的文字（抽屉当前不显示片段，留着是给
    /// `SessionDrawer` 的 `matchSnippet` 参数用的，暂时为 nil）。
    var drawerSessionMatches: [String: String] {
        let q = drawerQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [:] }
        var hit: [String: String] = [:]
        for s in filteredSessions {
            let title = s.title ?? ""
            if title.lowercased().contains(q) {
                hit[s.id] = title
            }
        }
        return hit
    }

    /// 命中的产物。按文件名匹配，只取有归属会话的那些 ——
    /// 没有 sessionId 的产物点进去无处可去。
    var drawerArtifactMatches: [ArtifactMatch] {
        let q = drawerQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }

        // 会话标题用一次字典，避免每条产物都去 sessions 里线性找一遍。
        var titleById: [String: String] = [:]
        for s in sessions {
            titleById[s.id] = (s.title?.isEmpty == false) ? s.title! : "新对话"
        }

        var out: [ArtifactMatch] = []
        for g in ArtifactStore.shared.groups {
            let sessionTitle = titleById[g.id] ?? "新对话"
            for item in g.items where item.name.lowercased().contains(q) {
                out.append(ArtifactMatch(id: item.id,
                                         sessionId: g.id,
                                         sessionTitle: sessionTitle,
                                         name: item.name,
                                         kind: item.kind))
            }
        }
        return out
    }

    /// 从抽屉里点了某个会话。
    ///
    /// 这里刻意委托给原版 `switchToSession`，不自己改 navigationPath。
    /// 自己写那版漏了三件事：
    ///   1. iPad 宽屏分支 —— 宽屏不用导航栈，走的是 selectedSessionId，
    ///      自己 append 一遍等于什么都没选上；
    ///   2. `shouldAnimateSessionPush` 的动画判定；
    ///   3. `currentStackSessionId` 的同步 —— 不写它，
    ///      `previousStackSessionId` 会错位，AIChatView 的 onAppear /
    ///      onDisappear 记号跟着乱。
    func openSessionFromDrawer(_ id: String) {
        if Self.isNewSessionId(id) {
            handleNewChatRequest()
            return
        }
        switchToSession(id)
    }
}

// MARK: - 关掉系统返回手势

/// 让 `UINavigationController.interactivePopGestureRecognizer` 失效。
///
/// 为什么不用 SwiftUI 的办法：SwiftUI 没有暴露「禁用交互式返回」的开关。
/// iOS 16+ 有个 `.toolbar(.hidden)` 之类的曲线方案都要连导航栏一起动，
/// 而导航栏必须留着（返回键在那儿）。所以直接伸手到 UIKit 那一层。
///
/// 为什么是 `background` 而不是别的修饰符：它需要一个「确实被挂进
/// 视图树」的落点，`background` 放一个零尺寸的 UIView 正好，不影响布局。
///
/// 为什么在 `didMoveToWindow` 里做：`makeUIView` 阶段视图还没进 window，
/// 响应链是断的，`next` 走不到 `UINavigationController`。
private struct InteractivePopGestureDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { PopGestureOffView() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class PopGestureOffView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            setPopGesture(enabled: false)
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            // 离开视图树时恢复 —— 否则这条设置会跟着
            // UINavigationController 一直留下去，影响以后挂上来的页面。
            if newWindow == nil { setPopGesture(enabled: true) }
        }

        private func setPopGesture(enabled: Bool) {
            // 沿响应链往上找 UINavigationController。
            // 不写死层数：SwiftUI 的 hosting 层级会随版本变，
            // 硬编码 next.next 一旦不对就静默失效。
            var responder: UIResponder? = self
            while let r = responder {
                if let nav = r as? UINavigationController {
                    nav.interactivePopGestureRecognizer?.isEnabled = enabled
                    return
                }
                responder = r.next
            }
        }
    }
}

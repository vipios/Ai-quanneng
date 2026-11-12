//
//  ContentView+Drawer.swift
//  全能AI - 把抽屉接进 iPhone 的 stackLayout
//
//  这里做三件事：
//    1. 把 iPhone 的 `stackLayout` 包进 `DrawerContainer`
//    2. 给 `SessionDrawer` 备好它要的数据（会话、产物、搜索命中）
//    3. 关掉 `NavigationStack` 的系统返回手势，让左边缘右滑归抽屉
//
//  刻意不做的事：
//    - 不改 `stackLayout` 本身：`NavigationStack`、`sessionList`、
//      `navigationDestination`、`AIChatView` 全是原版，这里只套一层。
//    - 不改 iPad 的 `splitLayout`：那边本来就有常驻侧栏，不需要抽屉。
//
//  手势归属：同一条左边缘、同一方向，原版是「返回上一页」，现在是「拉开抽屉」。
//  做法是 `InteractivePopGestureDisabler` 把
//  `interactivePopGestureRecognizer.isEnabled` 置 false。
//  为什么不靠速度/位移区分：两者起手区域完全重叠，任何阈值都会在某一档手感下
//  失灵，定死归属只有一种结果。代价是返回只能点导航栏左上角 `‹` —— 那个按钮
//  是系统原生的，热区、动画、无障碍全部原样，抽屉手势层还在导航栏那 44pt
//  让了位，所以四周都能按。
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
    /// 安全区不从这里往下传：`geo.safeAreaInsets` 在这棵树上可能是 0，
    /// 传下去等于把卡片出血的开关关掉。改由 `DrawerContainer` 直接问窗口要，
    /// 见 `windowMetrics()`。
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
            // 不要再加 `.environmentObject(drawerState)`：抽屉靠
            // `DrawerCloseAction` 收自己，容器顶层已经注过一次。这里再注
            // 只会让抽屉重新变成订阅者，拖动时每帧重算整棵抽屉。
        } content: {
            stackLayout
                // 必须挂在 NavigationStack 内部，才能沿响应链找到那个
                // UINavigationController。
                .background(InteractivePopGestureDisabler())
        }
    }

    // MARK: - 抽屉搜索的匹配结果
    //
    // 抽屉不是 List，搜索得自己算。口径和原版侧栏一致：会话按标题匹配、
    // 产物按文件名匹配。原版侧栏那套片段高亮是给 List 的 AttributedString
    // 用的，抽屉里行结构不同，硬套会错位。

    /// 抽屉搜索是否生效。
    var drawerIsSearching: Bool {
        !drawerQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 命中的会话 id → 标题（作为 `SessionDrawer` 的 `matchSnippet` 参数）。
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

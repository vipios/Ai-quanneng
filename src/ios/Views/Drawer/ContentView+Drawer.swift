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
//  做法在 `EdgePanOverlay.Coordinator.syncWindowPans` 里：从 window 递归找所有
//  `UINavigationController`，把 `interactivePopGestureRecognizer.isEnabled` 置
//  false，再给它挂一条对抽屉 pan 的**永久失败依赖**（UIKit 在 push 完会把这个
//  isEnabled 重置回 true，只有 require(toFail:) 挡得住）。
//
//  这里曾经挂过一个 `InteractivePopGestureDisabler` 的 UIViewRepresentable，
//  作为 `.background` 贴在 NavigationStack 上 —— 它走响应链 `next` 永远碰不到
//  导航控制器，静默 return，一次都没生效过。真正的修复搬到手势协调器之后它就
//  是纯粹的尸体，已删除。
//
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
    /// 安全区不读 `geo.safeAreaInsets`（在这棵树上恒为 0，见调用点注释），
    /// 调用方传的是 `geo.frame(in: .global)` 量到的真实位置：
    ///
    ///   · `containerHeight` = `geo.size.height`（安全区那块矩形的高，839）
    ///   · `top`             = `geo` 在窗口里的 minY（59）
    ///   · `windowHeight`    = 整屏高（932）
    func stackLayoutWithDrawer(width: CGFloat,
                               containerHeight: CGFloat,
                               top: CGFloat,
                               windowHeight: CGFloat) -> some View {
        DrawerContainer(width: width,
                        containerHeight: containerHeight,
                        top: top,
                        windowHeight: windowHeight) {
            SessionDrawer(
                topInset: top,
                bottomInset: max(0, windowHeight - top - containerHeight),
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
            // 原版 NavigationStack 原样塞进来，一个修饰符都不挂。
            // 曾经在这里贴过 `.background(InteractivePopGestureDisabler())`，
            // 从未生效（原因见文件头），已删。
            stackLayout
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

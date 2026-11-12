//
//  SessionDrawer.swift
//  全能AI - 抽屉里的会话列表
//
//  结构：标题 + 搜索 + 两个入口（全部产物 / 新建任务）+ 产物折叠区 + 分组会话列表。
//
//  行渲染直接复用现成的 `SessionStackRow`，不另造一套：那一行里有运行指示、
//  未读徽标、高亮匹配片段、拖拽、长按菜单、文件夹归属背景，重写必然漏。
//  但外层容器不复用 —— 原来 `List` + `Section` 的 chrome（分组头吸顶、
//  侧滑删除、多选）是为「列表是主界面」设计的，抽屉只有「屏宽 − 54」宽，
//  那些 chrome 会挤成一团。所以这里用 ScrollView + VStack，分组头自己画。
//

import SwiftUI

// MARK: - 抽屉主体

struct SessionDrawer: View {

    /// 收自己的入口（点会话 / 关闭键 / 新建任务之后）。
    ///
    /// 不要换成 `@EnvironmentObject DrawerState`：那是订阅，progress 拖动时
    /// 每帧都变，整棵抽屉会跟着每帧重算，而抽屉只用它做「关自己」一件事。
    @Environment(\.drawerClose) private var drawerClose

    /// 会话数据。由 ContentView 传进来，抽屉不自己读库 —— 两处各读一次
    /// 就会出现「列表已更新、抽屉还是旧的」。
    let sessions: [ChatSession]
    let folders: [ChatFolder]
    let groups: [SidebarGroup]
    let currentSessionId: String?

    /// 产物数据源。折叠区和副标题里的产物总数都来自它。
    @ObservedObject var artifactStore: ArtifactStore

    /// 每个会话的运行态。抽成闭包而不是传整张 Set，是为了不让抽屉在
    /// 任何一个会话的运行态变化时整块重建 —— 只有真正读到的行会刷。
    let isActive: (String) -> Bool
    let isSuspended: (String) -> Bool

    /// 搜索
    @Binding var query: String
    let isSearching: Bool
    /// 搜索命中的会话 id → 匹配片段。命中「产物」的那部分单独给。
    let sessionMatches: [String: String]
    let artifactMatches: [ArtifactMatch]

    /// 动作
    let menuActions: SessionMenuActionChannel
    let onNewChat: () -> Void
    let onOpenSettings: () -> Void
    let onSearchChanged: (String) -> Void

    /// 折叠状态。抽屉自己记 —— 这是纯展示偏好，不必回写全局。
    @State private var collapsed: Set<String> = []

    /// 「全部产物」折叠区是否展开（R46：原地折叠展开，不跳页）。
    @State private var artifactsExpanded = false

    /// 搜索框焦点
    @FocusState private var searchFocused: Bool

    // MARK: 底色 [R83]

    /// 抽屉底色。浅色 #fbfbfd —— 只比纯白暗一点点，白卡片摆上去才有薄阴影；
    /// 深色用 secondarySystemGroupedBackground。
    ///
    /// 单独提出来是因为它现在有三处要画（主体 + 上下两条补边），
    /// 三处颜色必须逐字相同，否则补边会比主体亮一档、接缝反而更明显。
    static var paper: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.secondarySystemGroupedBackground
                : UIColor(red: 0xfb / 255.0, green: 0xfb / 255.0, blue: 0xfd / 255.0, alpha: 1)
        })
    }

    // `DrawerWindow.metrics()` 是 @MainActor 的（要问 UIWindow），
    // 所以这三个都得跟着标，否则 Swift 6 严格并发下是编译错误。
    @MainActor private static var topInset: CGFloat { DrawerWindow.metrics()?.top ?? 0 }
    @MainActor private static var bottomInset: CGFloat { DrawerWindow.metrics()?.bottom ?? 0 }

    /// 补到屏幕边缘的一条底色。
    ///
    /// `alignment: .top` 的补边要往上顶（-h），`.bottom` 往下压（+h）——
    /// 方向反了就是「补边盖住内容」或者「补边跑到屏幕外」，两种都看不出原因。
    @MainActor
    private static func paperCap(_ height: CGFloat, up: Bool) -> some View {
        paper
            .frame(height: height)
            .offset(y: up ? -height : height)
            .allowsHitTesting(false)
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── 标题 ──
            titleBar

            // ── 搜索 ──
            searchBar

            // ── 两个入口（全部产物 / 新建任务）──
            // [R46-对齐R40] 从底部上移到搜索框正下方。
            actionBar

            // ── 列表 ──
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    if isSearching {
                        searchResults
                    } else {
                        // 「全部产物」折叠区：点开后每个对话一个产物文件夹
                        if artifactsExpanded {
                            artifactsFold
                        }
                        normalList
                    }
                }
                // 底部留白 = 齿轮直径 60 + 底边距 16 + 余量 10 = 88。
                // 齿轮是 overlay 里的绝对定位元素、不参与 VStack 布局，
                // 少了这段留白最后一条会话会被齿轮盖住点不到。
                .padding(.bottom, 88)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        // 抽屉底色 #fbfbfd：只比纯白暗一点点，白卡片摆上去才有那层薄阴影可看。
        // 深色模式用 secondarySystemGroupedBackground。
        //
        // 只用 background 忽略上下安全区，不给整个 VStack 加：内容（标题、
        // 搜索框、列表）必须待在安全区内，否则标题顶到状态栏底下、最后一行
        // 被 home indicator 压住。左右也不忽略 —— 右边要留 peek 那条给卡片。
        .background(Self.paper)
        .background(Self.paper.ignoresSafeArea(edges: .vertical))
        // [R83] 上下各补一条同色，铺到屏幕边缘。
        //
        // 抽屉的布局帧是「安全区那块矩形」（15 Pro Max 上是 y 59…898），
        // 状态栏那 59pt 和 home indicator 那 34pt 都不在里面。上面那句
        // `.ignoresSafeArea` 在这棵树上没能把底色拉出去 —— 用户截图里顶上
        // 那条白边就是它，原话「背景没做到满屏，只做到状态栏下方」。
        //
        // 所以不再指望安全区传播，直接拿窗口实测值画两条同色块：
        // 一条往上顶 top，一条往下压 bottom。同色，接缝看不出来；
        // 取不到窗口时高度为 0，等于没加。
        .background(alignment: .top) { Self.paperCap(Self.topInset, up: true) }
        .background(alignment: .bottom) { Self.paperCap(Self.bottomInset, up: false) }
        // 右下角悬浮齿轮，点它开原版 SettingsSheet。
        .overlay(alignment: .bottomTrailing) {
            settingsGear
        }
        // 会话真的切过去了才关抽屉。
        //
        // 不写在点击回调里：行本身是 Button，点击先走 `menuActions.send(.open)`，
        // 再由 ContentView 改 currentSessionId。观察它变化既能保证「切成功才关」，
        // 也不用和 Button 抢手势优先级。
        //
        // 条件是「变了就关」，不是「变成某个会话才关」—— 删除当前会话后
        // currentSessionId 变 nil 也要关，否则抽屉一直开着盖住列表。
        .onChange(of: currentSessionId) { _ in
            // 不用再判断 isOpen：关一个已经关着的抽屉本来就什么都不发生，
            // 而为了那个判断去订阅 state，代价是整棵抽屉每帧重算。
            drawerClose.close()
        }
        .task {
            // R46：进抽屉时刷新产物分组（按对话聚合），供折叠区和副标题用。
            await artifactStore.refresh(sessions: sessions)
        }
    }

    /// 右下角悬浮齿轮：accentColor 底 + 白色粗齿轮，60pt，底边距 16。
    ///
    /// 不能用白底细线：抽屉底色 #fbfbfd 本来就白，再贴一个白气泡，
    /// 齿轮几乎没有存在感，用户找不到设置入口。
    private var settingsGear: some View {
        Button {
            onOpenSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Color.accentColor, in: Circle())
                .shadow(color: Color.accentColor.opacity(0.35), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14)
        .padding(.bottom, 16)
        .accessibilityLabel("设置")
    }

    // MARK: 标题

    private var titleBar: some View {
        // 标题居中、关闭按钮贴右 —— 必须用 ZStack 而不是 HStack + Spacer：
        // HStack 里标题的居中位置取决于右侧按钮宽度，会被推偏约 19pt，
        // 改 Spacer 权重只能凑近似值。
        ZStack {
            // 字号取自设计稿 .dw-title（27 / bold / kerning −0.54）与 .dw-sub（12.5）。
            VStack(spacing: 5) {
                Text(sidebarTitle)
                    .font(.system(size: 27, weight: .bold))
                    .kerning(-0.54)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // 居中容器要占满宽度，否则 ZStack 按内容宽度居中，
            // 标题会挤在左侧按钮旁边而不是整条的中线。
            .frame(maxWidth: .infinity)
            // 标题左右各留出关闭按钮的 28pt + 一点间隙，长标题才不会被
            // 按钮压住。注意这是**对称**的，所以中线不偏 —— 只在右侧留
            // 就会把标题往左推，居中又白做了。
            .padding(.horizontal, 36)

            HStack {
                Spacer(minLength: 0)
                Button {
                    drawerClose.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭抽屉")
            }
        }
        // 左右留一样的内边距：居中是对称留白算出来的中线，两侧不等就偏。
        // 这里右侧还要额外让出关闭按钮的 28pt，否则长标题会顶到按钮下面。
        // 设计稿 .dw-head 是 22，但那是「没有关闭按钮」的版式；这里必须
        // 让出 28pt 按钮，所以左右各 22 → 取 22（按钮用 overlay 压边不占位）。
        .padding(.leading, 22)
        .padding(.trailing, 22)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private var sidebarTitle: String {
        // 固定文案，不用 SOUL 名 —— 抽屉是全局入口，不是某个角色的人格页。
        "全能AI管理"
    }

    private var subtitle: String {
        if isSearching && !query.isEmpty {
            let n = sessionMatchCount + artifactMatches.count
            return n == 0 ? "没找到" : "找到 \(n) 项"
        }
        let artifactCount = artifactStore.groups.reduce(0) { $0 + $1.items.count }
        return "\(sessions.count) 个对话 · \(artifactCount) 个产物"
    }

    // MARK: 搜索

    private var searchBar: some View {
        // 尺寸取自设计稿 .dw-search：高 38 / 圆角 11 / gap 8 / 内边距 11，
        // 底色 tertiarySystemFill，聚焦时转白 + 蓝色光晕。
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索对话与产物", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15.5))
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: query) { newValue in
                    onSearchChanged(newValue)
                }

            if !query.isEmpty {
                // 设计稿的清空键是 20pt 实心灰圆 + 白色叉，不是
                // `xmark.circle.fill`（那个是深灰底 + 白色叉，但边缘是
                // 透明抗锯齿，压在浅灰搜索框上会发毛）。自己拼一个圆。
                Button {
                    query = ""
                    onSearchChanged("")
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color(.tertiaryLabel), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(searchFocused
                      ? Color(.secondarySystemGroupedBackground)
                      : Color(.tertiarySystemFill))
        )
        // 聚集光晕：等价 .dw-search.focus 的 box-shadow 0 0 0 3px rgba(0,122,255,.16)。
        // SwiftUI 没有 ring shadow，用一圈描边模拟。
        .overlay {
            if searchFocused {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    // MARK: 正常列表

    private var normalList: some View {
        ForEach(groups) { group in
            groupHeader(group)

            if !collapsed.contains(group.id) {
                ForEach(group.ids, id: \.self) { sid in
                    row(sid, inFolder: group.folderId != nil,
                        isLast: group.isLastMemberRow(sid))
                }
            }

            // 文件夹里还有更多命中没显示
            if group.hiddenMatchCount > 0, !collapsed.contains(group.id) {
                showMoreRow(group)
            }
        }
    }

    private func groupHeader(_ group: SidebarGroup) -> some View {
        let isCollapsed = collapsed.contains(group.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isCollapsed { collapsed.remove(group.id) }
                else { collapsed.insert(group.id) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                // [R63-对齐设计稿] .dw-sec: 12px/600, letter-spacing .03em
                // .03em × 12 = 0.36pt
                Text(localizedGroupLabel(group.label))
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.36)
                Spacer(minLength: 0)
                Text("\(group.ids.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            // .dw-sec padding: 12 22 6
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.label) 分组，\(group.ids.count) 个会话，\(isCollapsed ? "已折叠" : "已展开")")
    }

    /// 把 ContentView 传进来的英文分组 label（"Today"/"Yesterday"/...）映射成中文。
    /// 只影响抽屉这一屏；主界面侧栏另有它自己的分组展示。
    private func localizedGroupLabel(_ label: String) -> String {
        switch label {
        case "Pinned":     return "已置顶"
        case "Today":      return "今天"
        case "Yesterday":  return "昨天"
        case "This Week":  return "本周"
        case "This Month": return "本月"
        case "Earlier":    return "更早"
        default:           return label
        }
    }

    private func row(_ sid: String, inFolder: Bool, isLast: Bool) -> some View {
        let session = sessions.first(where: { $0.id == sid })
            ?? .missingRowPlaceholder(sid)

        // 不要再在这行外面套 `.onTapGesture { onOpenSession(sid) }`：
        // SessionStackRow 内部本身就是 Button，会走 `menuActions.send(.open)`
        // → 原版 `switchToSession`（替换栈 + 按 shouldAnimateSessionPush 决定
        // 动画）。外面再套一层等于同一个会话开两次，而且路径口径不同
        // （append 会把栈堆起来）—— 点一次抽屉、后退一次还停在原页面。
        //
        // 关抽屉交给下面 `.onChange(of: currentSessionId)`，不依赖点击顺序。
        return SessionStackRow(
            session: session,
            isActive: isActive(sid),
            isSuspended: isSuspended(sid),
            highlightQuery: isSearching ? query : nil,
            matchSnippet: isSearching ? sessionMatches[sid] : nil,
            isRegeneratingTitle: false,
            inFolder: inFolder,
            isLastInFolder: isLast,
            menuActions: menuActions
        )
        .padding(.horizontal, 8)
        .background {
            if currentSessionId == sid {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .padding(.horizontal, 8)
            }
        }
        // 点的是当前正在聊的那条时，id 不变 → 上面的 onChange 不触发 → 抽屉
        // 杵在那儿。这里补一个并行轻点，只处理这一种情况。
        //
        // 必须用 `.simultaneousGesture`：行本身是 Button，`.onTapGesture`
        // 会被它吃掉。只对当前会话生效，别的会话仍交给 onChange 在切换
        // 成功之后关 —— 提前关会在新页面上看到抽屉飘一下。
        // 长按菜单不受影响：Tap 和 LongPress 是两种手势。
        .simultaneousGesture(
            TapGesture().onEnded {
                guard currentSessionId == sid else { return }
                drawerClose.close()
            }
        )
    }

    private func showMoreRow(_ group: SidebarGroup) -> some View {
        Text("还有 \(group.hiddenMatchCount) 个匹配…")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
    }

    // MARK: 搜索结果

    private var sessionMatchCount: Int {
        groups.reduce(0) { $0 + $1.ids.count }
    }

    @ViewBuilder
    private var searchResults: some View {
        if query.isEmpty {
            // 空搜索不显示结果区，回落到正常列表
            normalList
        } else if sessionMatchCount == 0 && artifactMatches.isEmpty {
            emptySearch
        } else {
            if sessionMatchCount > 0 {
                searchGroupHeader("对话", count: sessionMatchCount)
                ForEach(groups) { group in
                    ForEach(group.ids, id: \.self) { sid in
                        row(sid, inFolder: group.folderId != nil,
                            isLast: group.isLastMemberRow(sid))
                    }
                }
            }

            if !artifactMatches.isEmpty {
                searchGroupHeader("产物", count: artifactMatches.count)
                ForEach(artifactMatches) { m in
                    artifactRow(m)
                }
            }
        }
    }

    private func searchGroupHeader(_ title: String, count: Int) -> some View {
        HStack {
            // [R63] 与 .dw-sec 同版式，两处都改才不打架
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.36)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func artifactRow(_ m: ArtifactMatch) -> some View {
        Button {
            // R28：点产物不是「跳到产物页」，而是回到它所属的对话并定位。
            //
            // 走 menuActions 而不是 onOpenSession：这是原版的行点击通道，
            // ContentView 那边是 switchToSession(sid, animated: true) ——
            // 替换栈、按规则决定动画。onOpenSession 走的是 append，会把
            // 导航栈越堆越深，抽屉来回点几次之后返回要按很多下。
            // 关抽屉交给底部的 .onChange(of: currentSessionId)。
            menuActions.send(.open(m.sessionId))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: m.kind.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(m.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(m.sessionTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("产物 \(m.name)，属于对话 \(m.sessionTitle)")
    }

    private var emptySearch: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.quaternary)
            Text("没有匹配")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("「\(query)」在对话和产物里都没找到。")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 60)
    }

    // MARK: 两个入口（全部产物 / 新建任务）

    /// 搜索框正下方的两个入口，上下排列。
    ///
    /// 「图标 + 文字」作为一个整体在行内居中，徽标贴图标、折叠箭头绝对贴右 ——
    /// 箭头不参与居中计算，否则它会把整体往左推 12pt，展开/收起时文字还会跳。
    ///
    /// 尺寸：高 48 / 字号 16 / 图标底 29 / 图标 16 / 圆角 13 / 徽标 16 /
    /// 横向 14。参照是紧凑的行，不是厚卡片。
    private var actionBar: some View {
        VStack(spacing: 10) {

            // ── 上：全部产物（原地折叠展开）──
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    artifactsExpanded.toggle()
                }
            } label: {
                DrawerEntry(
                    icon: "folder",
                    iconWeight: .medium,
                    iconColor: Color(.systemIndigo),
                    iconBackground: Color(.systemIndigo).opacity(0.12),
                    title: "全部产物",
                    titleColor: .primary,
                    titleWeight: .medium,
                    background: Color(.secondarySystemGroupedBackground),
                    hasShadow: true,
                    badge: artifactTotalCount,
                    caretExpanded: artifactsExpanded
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("全部产物，\(artifactTotalCount) 个，\(artifactsExpanded ? "已展开" : "已收起")")

            // ── 下：新建任务 ──
            // 淡蓝底 + 蓝字（rgba(0,122,255,.09)），不是整块饱和蓝：
            // 淡蓝底跟上面那张白卡只差一档，两张摆一起才是一套。
            Button {
                onNewChat()
                drawerClose.close()
            } label: {
                DrawerEntry(
                    icon: "plus",
                    iconWeight: .semibold,
                    iconColor: Color.accentColor,
                    iconBackground: Color.accentColor.opacity(0.14),
                    title: "新建任务",
                    titleColor: Color.accentColor,
                    titleWeight: .semibold,
                    background: Color.accentColor.opacity(0.09),
                    hasShadow: false,
                    badge: nil,
                    caretExpanded: nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建任务")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    /// 产物总数。
    private var artifactTotalCount: Int {
        artifactStore.groups.reduce(0) { $0 + $1.items.count }
    }

    // MARK: 全部产物折叠区

    /// [R46-对齐R40] 点「全部产物」后原地展开的折叠区：每个对话一个产物文件夹行。
    /// 点击某行 = 回到该对话（复用「在对话中定位」路径）。
    private var artifactsFold: some View {
        VStack(spacing: 0) {
            if artifactStore.groups.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Text("还没有产物")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            } else {
                ForEach(artifactStore.groups) { g in
                    Button {
                        // 回到该对话（产物折叠区点击 = 定位到对话）
                        menuActions.send(.open(g.id))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28, height: 28)
                                .background(Color.accentColor.opacity(0.10),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(g.title.isEmpty ? "未命名" : g.title)
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(g.items.count)")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("产物 \(g.title)，\(g.items.count) 个")
                }
            }
        }
        .padding(.vertical, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - 入口卡片

/// 抽屉里「全部产物 / 新建任务」共用的行版式。两张卡只有配色和尾部元素不同，
/// 几何完全一致 —— 分开写必然有一处漏改。
///
/// 用 ZStack 而不是 HStack + Spacer：「图标 + 文字」作为一个整体居中，
/// 折叠箭头用 overlay 绝对贴右，不参与居中计算（放进 HStack 会把整体
/// 往左推约 12pt，展开/收起时文字位置还会跳）。
///
/// 角标贴图标右上角，用卡片底色描一圈边让它「浮」起来。
private struct DrawerEntry: View {

    let icon: String
    let iconWeight: Font.Weight
    let iconColor: Color
    let iconBackground: Color

    let title: String
    let titleColor: Color
    let titleWeight: Font.Weight

    let background: Color
    let hasShadow: Bool

    /// nil = 不显示角标（「新建任务」）。
    let badge: Int?
    /// nil = 不显示折叠箭头（「新建任务」）。
    let caretExpanded: Bool?

    var body: some View {
        ZStack {
            // 主体：图标 + 文字，整体居中
            HStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: iconWeight))
                        .foregroundStyle(iconColor)
                        .frame(width: 29, height: 29)
                        .background(iconBackground,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    if let n = badge, n > 0 {
                        Text("\(n)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color(.systemIndigo), in: Capsule())
                            .overlay {
                                Capsule()
                                    .strokeBorder(Color(.secondarySystemGroupedBackground),
                                                  lineWidth: 1.6)
                            }
                            .offset(x: 5, y: -4)
                    }
                }

                Text(title)
                    .font(.system(size: 16, weight: titleWeight))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
            }

            // 折叠箭头绝对贴右，不参与居中计算
            if let expanded = caretExpanded {
                HStack {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(background,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        // 设计稿 box-shadow 0 1px 3px rgba(0,0,0,.055) + 0 0 0 .5px rgba(0,0,0,.04)。
        // 「新建任务」是淡蓝底，设计稿明确 box-shadow:none —— 有阴影反而
        // 像浮起来的按钮，两张卡就不再是一套了。
        .shadow(color: hasShadow ? .black.opacity(0.055) : .clear, radius: 3, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

// MARK: - 产物匹配模型

/// 搜索结果里的一条产物。
///
/// 刻意不新造一套 Kind：直接复用 `ArtifactStore` 里现成的 `ArtifactItem.Kind`。
/// 那边已经有 8 类（image/video/audio/document/archive/code/data/other）和
/// 对应 SF Symbol，再造一个只有 5 类的枚举，两边的图标迟早会对不上。
struct ArtifactMatch: Identifiable, Equatable {
    let id: String
    /// 所属会话 id —— 点它不是开产物，是回到那个对话。
    let sessionId: String
    let sessionTitle: String
    let name: String
    let kind: ArtifactItem.Kind
}

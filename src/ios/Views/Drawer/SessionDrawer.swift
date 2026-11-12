//
//  SessionDrawer.swift
//  全能AI - 抽屉里的会话列表
//
//  R25 / R28 的落地。抽屉内容 = 标题 + 搜索 + 两个入口 + 产物折叠区 + 分组会话列表。
//  R46 对齐 R40 模板：标题固定「全能AI管理」，副标题「N 个对话 · N 个产物」，
//  两个入口（全部产物 / 新建任务）上移到搜索框下方，「全部产物」改为原地折叠展开。
//
//  刻意复用的东西：行渲染直接用现成的 `SessionStackRow`，不另造一套。
//  理由很实在 —— 那一行里有运行指示、未读徽标、高亮匹配片段、拖拽、
//  长按菜单、文件夹归属背景，重写一遍必然漏东西，而且以后原版改了这里
//  也不会跟着变。抽屉只是把它从 List 挪到了 VStack 里。
//
//  刻意不复用的东西：外层容器。原来那套 `List` + `Section` 的 chrome
//  （分组头吸顶、侧滑删除、多选）是为「列表是主界面」设计的；抽屉里宽度
//  只有 318pt，那些 chrome 会挤成一团。所以这里用 ScrollView + VStack，
//  分组头自己画。
//

import SwiftUI

// MARK: - 抽屉主体

struct SessionDrawer: View {

    /// 抽屉状态（用来在点会话后关自己）
    @EnvironmentObject private var drawerState: DrawerState

    /// 会话数据。由 ContentView 传进来，抽屉不自己读库 —— 两处各读一次
    /// 就会出现「列表已更新、抽屉还是旧的」。
    let sessions: [ChatSession]
    let folders: [ChatFolder]
    let groups: [SidebarGroup]
    let currentSessionId: String?

    /// 产物数据源。R46 起「全部产物」改为抽屉内原地折叠展开（对齐 R40），
    /// 需要按对话聚合的产物分组来渲染折叠区 + 算副标题里的产物总数。
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
                // [R28-设置齿轮不被压住] 底部留白 = 齿轮 52 + 底边距 20 + 一点余量。
                // 齿轮是 overlay 里的绝对定位元素，不参与 VStack 布局，
                // 少了这段留白最后一个会话会被齿轮盖住点不到。
                // [R51] 76 → 80：齿轮底边距从 70 改 20 后，
                // 留白同步对齐（52 + 20 + 余量 8）。
                .padding(.bottom, 80)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(.systemGroupedBackground))
        // [R28-设置入口右下角] 设置入口从导航栏 `.topBarLeading` 挪到这里：
        // 抽屉右下角一枚 52pt 悬浮齿轮，点它直接开原版 SettingsSheet。
        //
        // 抽屉里齿轮是唯一固定在右下角的元素，用 overlay 浮在列表之上，
        // 不参与 VStack 布局。
        .overlay(alignment: .bottomTrailing) {
            settingsGear
        }
        // 会话真的切过去了才关抽屉。
        //
        // 为什么不写在点击回调里：行是 SessionStackRow(内部 Button)，
        // 点击先经过原版通道 `menuActions.send(.open)`，再由 ContentView
        // 改 currentSessionId。在这里观察它的变化，既能保证「切成功才关」，
        // 也不用和行的 Button 抢手势优先级。旧写法是先 onOpenSession 再
        // close，顺序反了会在新页面上看到抽屉飘一下。
        //
        // [R52-删对话后抽屉不关] 原来只在 newValue != nil 时才关（切到
        // 某会话）。但删除当前会话后 currentSessionId 变 nil（回到列表），
        // 这个条件不满足 → 抽屉一直开着、遮罩盖着，右侧还残留被删对话
        // 的画面。改成「变了就关」（不管切去会话还是回到列表）——
        // 从抽屉里点会话会走到这、删除后回列表也走到这，都该关。
        .onChange(of: currentSessionId) { _ in
            if drawerState.isOpen {
                drawerState.close()
            }
        }
        .task {
            // R46：进抽屉时刷新产物分组（按对话聚合），供折叠区和副标题用。
            await artifactStore.refresh(sessions: sessions)
        }
    }

    /// 右下角悬浮齿轮。
    ///
    /// [R53-齿轮样式] 用户原话「放大一些，用蓝色气泡，齿轮加粗」：
    /// 气泡 56pt（原 52），蓝底白齿轮（与「新建任务」主色一致），
    /// 图标加粗（.bold）。阴影保留两层防灰边。
    private var settingsGear: some View {
        Button {
            onOpenSettings()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: Circle())
                .shadow(color: Color.accentColor.opacity(0.35), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14)
        // [R51] 底边距从 70 改 20。70 是给「底部按钮区 54 + 间隙 16」留的，
        // R46 已把两个入口上移到搜索框下方、底部按钮区不存在了，
        // 齿轮还按 70 缩进就飘在半空。现在只留 20pt 贴住右下角，
        // Home 指示条区域由系统安全区垫开，不会压条。
        .padding(.bottom, 20)
        .accessibilityLabel("设置")
    }

    // MARK: 标题

    private var titleBar: some View {
        // 标题居中，关闭按钮浮在右侧 —— 用 ZStack 而不是 HStack + Spacer。
        //
        // 为什么不能用 HStack：
        //   HStack { 标题; Spacer(); 关闭按钮 } 里，标题的居中位置取决于
        //   右侧按钮的宽度。按钮 28pt + 右 padding，标题就会被推得偏离
        //   真正的中线约 19pt。改 Spacer 权重只能凑近似值，换个字号又歪。
        //
        // 用 ZStack 后两件事解耦：标题按整条宽度居中（不管右边有没有按钮），
        // 按钮单独贴右。这样以后加第二个按钮也不会再动标题的位置。
        ZStack {
            VStack(spacing: 1) {
                Text(sidebarTitle)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
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
                    drawerState.close()
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
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var sidebarTitle: String {
        // [R46-对齐R40] 抽屉标题固定「全能AI管理」，不再用 SOUL 名。
        "全能AI管理"
    }

    private var subtitle: String {
        if isSearching && !query.isEmpty {
            let n = sessionMatchCount + artifactMatches.count
            return n == 0 ? "没找到" : "找到 \(n) 项"
        }
        // [R46-对齐R40] 副标题 = 「N 个对话 · N 个产物」。
        let artifactCount = artifactStore.groups.reduce(0) { $0 + $1.items.count }
        return "\(sessions.count) 个对话 · \(artifactCount) 个产物"
    }

    // MARK: 搜索

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索对话与产物", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: query) { newValue in
                    onSearchChanged(newValue)
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    onSearchChanged("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
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
                Text(localizedGroupLabel(group.label))
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(group.ids.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)
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

        // 不要再在这行外面套 `.onTapGesture { onOpenSession(sid) }`。
        //
        // SessionStackRow 内部本身就是一个 Button，点了会走
        // `menuActions.send(.open(sid))` → ContentView 的
        // `switchToSession(sid, animated: true)`，那是原版路径：
        // 它会替换而不是追加导航栈，还会按 shouldAnimateSessionPush
        // 决定要不要动画。
        //
        // 外面再套一层 tap 就等于同一个会话开两次，而且两条路径口径不同
        // （onOpenSession 用的是 append，会把栈堆起来）。点一次抽屉、
        // 后退一次发现还在原页面，就是这么来的。
        //
        // 关抽屉交给 `.onChange(of: currentSessionId)` —— 会话真的切过去了
        // 才关，这不依赖点击事件的先后顺序，也不会和行的 Button 抢手势。
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
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
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

    /// [R52-上下排列] 搜索框正下方的两个入口。
    /// 用户原话：「他们俩没对齐，可以改成上下排列，不要一排，气泡统一。
    /// 背景蓝色字体白色」。两个入口各占一整行，同一个气泡样式
    /// （同高、同圆角、同内边距），「新建任务」用蓝底白字的主色。
    private var actionBar: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    artifactsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "folder")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 26, height: 26)
                            .background(Color.accentColor.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        let n = artifactStore.groups.reduce(0) { $0 + $1.items.count }
                        if n > 0 {
                            Text("\(n)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 14)
                                .frame(height: 14)
                                .background(Color.accentColor, in: Capsule())
                                .offset(x: 6, y: -5)
                        }
                    }
                    Text("全部产物")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)

            Button {
                onNewChat()
                drawerState.close()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.22),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("新建任务")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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

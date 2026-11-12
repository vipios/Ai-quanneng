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
//  只有「屏宽 − 54」左右，那些 chrome 会挤成一团。所以这里用 ScrollView + VStack，
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
                // [R28-设置齿轮不被压住] 底部留白 = 齿轮直径 + 底边距 + 一点余量。
                // 齿轮是 overlay 里的绝对定位元素，不参与 VStack 布局，
                // 少了这段留白最后一个会话会被齿轮盖住点不到。
                //
                // [R64] 齿轮从 52/24 改成 60/16，留白跟着重算：
                // 60 + 16 + 余量 10 = 86，取 88。
                // 不跟着改的后果很具体 —— 齿轮下移了 8pt、又胖了 8pt，
                // 原来 80 的留白刚好够不到，最后一条会话的下半截会被压住。
                .padding(.bottom, 88)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        // [R63-对齐设计稿] 抽屉底色 #fbfbfd。
        //
        // 原来用 systemGroupedBackground（浅色下是 #f2f2f7），比设计稿灰
        // 一档，白卡片摆上去对比不够，整块看着发闷。设计稿 :root 里
        // --bg 是 #f2f2f7 但那说的是「手机外框」，抽屉本身铺的是 .drawer
        // 的 #fbfbfd —— 只比纯白暗一点点，卡片才有那层薄阴影可看。
        // [R76-上下各缺一条] 底色必须**铺进上下安全区**。
        //
        // 抽屉的父容器（ContentView 的 GeometryReader → DrawerContainer）
        // 是遵守安全区布局的，所以抽屉这一层的 frame 上下各被切掉一截：
        // 上面是状态栏（44/59pt），下面是 home indicator（34pt）。
        // 那两截露出来的是窗口底色（纯白 #fff），而抽屉底色是 #fbfbfd ——
        // 只差一点点白，于是屏幕上就是「上面缺一条、下面缺一条」，
        // 一条比周围略白的窄带贴在抽屉上下两端（深色模式下更明显）。
        //
        // 修法只让**背景**忽略安全区，不给整个 VStack 加：
        //   · 内容（标题、搜索框、列表）必须继续待在安全区内，否则标题
        //     会被顶到状态栏底下、最后一行会被 home indicator 压住；
        //   · 只有底色需要出血，`.ignoresSafeArea(edges: .vertical)`
        //     正好只补上下两条，左右不动（右侧要留 peek 那条给卡片）。
        //
        // 不加 `.edges: .all` 的原因：左右一旦也忽略，抽屉底色会往左
        // 吃掉横屏时的左安全区、往右可能压到 peek 条上，得不偿失。
        .background(
            Color(UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.secondarySystemGroupedBackground
                    : UIColor(red: 0xfb / 255.0, green: 0xfb / 255.0, blue: 0xfd / 255.0, alpha: 1)
            })
            .ignoresSafeArea(edges: .vertical)
        )
        // [R28-设置入口右下角] 设置入口从导航栏 `.topBarLeading` 挪到这里：
        // 抽屉右下角一枚悬浮齿轮，点它直接开原版 SettingsSheet。
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
    /// [R64-蓝底加粗加大下移] 用户要求：「改成蓝色背景，齿轮加粗，齿轮整体
    /// 加大，在往下移动一些」。这是对 R63 那版（白底细线 52pt）的直接覆盖。
    ///
    /// R63 我按 ui.html 的 `.dw-gear` 做成了白底细线，理由是「白卡配白底
    /// 才是一套」。但那版在实际界面上是个问题：抽屉底色 #fbfbfd 本来就白，
    /// 又一个白气泡贴上去，齿轮几乎没有存在感 —— 用户找不到设置入口。
    /// 设计稿是静态图，看不出这个；真机上一眼就显。
    ///
    /// 参数：
    ///   底色    白 → accentColor（和「新建任务」同一个蓝，是主色而不是装饰）
    ///   齿轮    .regular → .bold（「加粗」）
    ///   尺寸    52 → 60（「整体加大」）
    ///   图标    26 → 30（跟着容器等比放，否则 60 的圈里会显得空）
    ///   阴影    黑 0.13 → 蓝 0.35；蓝底气泡要有蓝色投影才「浮」得起来
    ///   bottom  24 → 16（「往下移动一些」）
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
            // [R63-对齐设计稿] .dw-title / .dw-sub
            //   .dw-title: font-size 27, weight 700, letter-spacing -.02em（≈ -0.54）
            //              line-height 1.12 → 行距收紧
            //   .dw-sub:   12.5px，margin-top 5
            //   .dw-head:  padding 0 22 14，text-align center
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
        // 设计稿 .dw-head 是 22，但那是「没有关闭按钮」的版式；这里必须
        // 让出 28pt 按钮，所以左右各 22 → 取 22（按钮用 overlay 压边不占位）。
        .padding(.leading, 22)
        .padding(.trailing, 22)
        .padding(.top, 6)
        .padding(.bottom, 14)
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
        // [R63-对齐设计稿] .dw-search
        //   margin 0 18 16 / height 38 / radius 11 / gap 8 / padding 0 11
        //   底色 --fill = rgba(120,120,128,.12) → .tertiarySystemFill
        //   聚集时背景转白 + 3px 蓝色光晕（.dw-search.focus）
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

    /// 搜索框正下方的两个入口。
    ///
    /// [R63-对齐设计稿 + 上下排列]
    /// 版式来自用户明确要求：「要上下排列的，气泡上下宽一点，字体大一点」，
    /// 再叠「还有这个字体要居中」。设计稿 `.dw-entry` 原本是左右并排、
    /// 文字靠左，那套在里面要塞两个 136pt 的块，字号只能到 15。
    ///
    /// **文字居中**：设计稿是左对齐（图标 + 文字 + 箭头三段撑满）。
    /// 用户要求居中后，改成「图标 + 文字」作为一个整体在行内居中，
    /// 徽标贴图标、折叠箭头绝对贴右 —— 箭头不参与居中计算，
    /// 否则它会把整体往左推 12pt，两种状态下文字位置还会跳。
    ///
    /// [R68-尺寸回调到参照]
    /// 用户拿参照（WorkBuddy 手机端）比：「二个气泡也和他上下一样宽，
    /// 字体大小也一样」。R63 那版是**故意**做得比设计稿大一档的
    /// （56 高 / 17pt 字，原话「气泡上下宽一点，字体大一点」），
    /// 所以 17 本身就是「偏大」的值，不是参照值。这次往回收：
    ///
    ///   height  56 → 48    参照里是紧凑的行，不是厚卡片
    ///   .et     17 → 16    iOS 列表行的标准字号，比 17 小一档
    ///   .ei     34 → 29    图标底跟着行高收
    ///   svg     19 → 16    图标本身
    ///   radius  14 → 13    圆角跟着高度收，比例不塌
    ///   badge   18 → 16    角标跟着图标收
    ///   padding 16 → 14    横向留白跟着收
    ///
    /// 保留 R63 的两条：文字整体居中、箭头绝对贴右。
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
            // 设计稿 `.dw-entry.primary` 是**淡蓝底 + 蓝字**（rgba(0,122,255,.09)），
            // 不是整块饱和蓝 —— 那版是我之前自己加的，用户没要求过。
            // 淡蓝底跟上面那张白卡只差一档，两张摆一起才是一套。
            Button {
                onNewChat()
                drawerState.close()
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

/// 抽屉里「全部产物 / 新建任务」共用的行版式。
///
/// 单独抽一个 struct 而不是 ViewBuilder 函数，原因是这两张卡**只有配色
/// 和尾部元素不同**：几何完全一致（同高 56、同圆角 14、同图标底 34、
/// 同字号 17、同内边距 16）。任何一处分别写两遍，下次调高度必定漏一个。
/// 设计稿也是同一个 `.dw-entry` 类加 `.primary` 修饰符，这里直接对应。
///
/// **文字居中**（用户要求）：
/// 用 ZStack 而不是 HStack + Spacer：
///   · 主体是「图标 + 文字」的 HStack，整体在行内居中；
///   · 折叠箭头（`caretExpanded != nil` 时才有）用 overlay 绝对贴右，
///     不参与居中计算。若把它放进 HStack，它会把整体往左推约 12pt，
///     而且展开时箭头旋转不影响、收回时又变回去 —— 文字位置会跳。
///
/// 角标（`badge`）：贴图标右上角，用卡片底色描一圈边让它「浮」起来。
/// 这是设计稿 `.dw-entry .ei .badge-n` 的做法（`box-shadow:0 0 0 1.6px #fff`），
/// 比直接压在图标上清楚得多。
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

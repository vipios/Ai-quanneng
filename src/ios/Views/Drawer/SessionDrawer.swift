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
        // [R62-对齐设计稿] ui.html 的 .drawer 背景是 #fbfbfd（近白），
        // 不是系统的 systemGroupedBackground（#f2f2f7，偏灰）。
        // 差两个色阶，一眼能看出「抽屉比列表页更白」—— 那正是设计稿的意图：
        // 抽屉是一张浮起来的纸，卡片用纯白，纸本身也接近白但略暗一档，
        // 卡片靠阴影而不是靠底色对比来分离。
        //
        // 深色下用 secondarySystemGroupedBackground（比纯黑亮一档），
        // 保持同样的「纸 vs 卡片」层次。
        .background(Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.secondarySystemGroupedBackground
                : UIColor(red: 0xfb/255.0, green: 0xfb/255.0, blue: 0xfd/255.0, alpha: 1)
        }))
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
    /// [R62-对齐设计稿] 按 ui.html 的 .dw-gear 重做：
    ///   width/height 52、圆形、**白底**（var(--card)）、深色细线齿轮
    ///   （stroke-width 1.8，不是加粗实心）
    ///   shadow: 0 2px 12px rgba(0,0,0,.13) + 0 0 0 .5px rgba(0,0,0,.04)
    ///   right:14px；bottom: max(24px, safeArea+8px)
    ///
    /// ⚠️ 上一版（R53）是 56pt 蓝底白齿轮 + 加粗 —— 那是另一次改动，
    /// 与设计稿相反。截图（剪贴板截图 2026-11-12）里就是白色圆形 + 灰色细线齿轮。
    private var settingsGear: some View {
        Button {
            onOpenSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                .shadow(color: .black.opacity(0.13), radius: 6, y: 2)
                .overlay {
                    Circle().strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14)
        // 设计稿 bottom: max(24px, env(safe-area-inset-bottom) + 8px)。
        // overlay 里父视图已经把安全区考虑进布局，这里取 24 即可。
        .padding(.bottom, 24)
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
        // [R62-对齐设计稿] 尺寸全部取自 ui.html 的 .dw-head / .dw-title / .dw-sub：
        //   标题 27pt/700、letter-spacing -0.02em、行高 1.12
        //   副标题 12.5pt、距标题 5pt
        //   整块 padding: 0 22px 14px（左右 22、底部 14）
        // 原来这里是 26pt + separator 1pt + 底部 10pt，跟设计稿差一档。
        ZStack {
            VStack(spacing: 5) {
                Text(sidebarTitle)
                    .font(.system(size: 27, weight: .bold))
                    // CSS 的 -0.02em 换算成 SwiftUI 的 kerning：27 × -0.02 ≈ -0.54
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
                // 设计稿的抽屉里没有关闭按钮（向左滑或点遮罩关）。
                // 但 iOS 上没有「点外面关」的习惯动作提示，留一个更稳妥，
                // 只是把它做成极轻的样式，不抢标题的视觉重心。
                Button {
                    drawerState.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
                        .background(Color(.quaternarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭抽屉")
            }
        }
        // 设计稿：padding 0 22px 14px。左侧 22 对齐标题；右侧 22 里
        // 已经含了关闭按钮的位置，所以按钮不会顶到边。
        .padding(.horizontal, 16)
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
        // [R62-对齐设计稿] .dw-search:
        //   margin: 0 18px 16px；height: 38px；border-radius: 11px；
        //   background: var(--fill) = rgba(120,120,128,.12)；
        //   padding: 0 11px；gap: 8px；图标 15pt
        // 原来是 padding 9/7 让高度随内容浮动（约 34pt）+ 圆角 10 + 左右 12，
        // 跟设计稿的 38pt 定高 + 圆角 11 + 左右 18 不一致。
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
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
                // 设计稿 .dw-clear：20pt 圆形实心灰底 + 白色叉
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
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
                Text(localizedGroupLabel(group.label))
                    // [R62-对齐设计稿] .dw-sec：12pt / 600 / letter-spacing .03em
                    // = 12 × 0.03 ≈ 0.36pt 字距。原来是 11pt。
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.36)
                Spacer(minLength: 0)
                Text("\(group.ids.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            // 设计稿 padding: 12px 22px 6px
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

    /// [R62-上下排列] 搜索框正下方的两个入口，**上下各占一整行**。
    ///
    /// 用户原话：「要上下排列的，气泡上下宽一点，字体大一点」。
    ///
    /// 气泡规格（在 ui.html 的 .dw-entry 基础上放大）：
    ///   高度 46 → 56、图标底 27 → 34、主文字 15 → 17、图标 16 → 19、
    ///   圆角 12 → 14、内部 gap 7 → 10、左右内边距 12 → 16
    /// 其余（阴影、描边、色调）仍按设计稿：白底卡片 + 双层细阴影。
    /// 「新建任务」不是整块蓝底 —— 图标蓝 + 文字蓝。
    private var actionBar: some View {
        VStack(spacing: 10) {
            // ── 上：全部产物（带数量徽标 + 右侧箭头，点开原地折叠）──
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    artifactsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "folder")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Color(.systemIndigo))
                            .frame(width: 34, height: 34)
                            .background(Color(.systemIndigo).opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        let n = artifactStore.groups.reduce(0) { $0 + $1.items.count }
                        if n > 0 {
                            Text("\(n)")
                                .font(.system(size: 11, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Color(.systemIndigo), in: Capsule())
                                // 设计稿 box-shadow:0 0 0 1.6px #fff —— 用描边模拟
                                .overlay {
                                    Capsule().strokeBorder(Color(.secondarySystemGroupedBackground),
                                                           lineWidth: 1.8)
                                }
                                .offset(x: 6, y: -5)
                        }
                    }
                    Text("全部产物")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // .caret 展开时 rotate(90deg) → 展开后箭头朝下
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(artifactsExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                // 设计稿 shadow: 0 1px 3px rgba(0,0,0,.055) + 0 0 0 .5px rgba(0,0,0,.04)
                .shadow(color: .black.opacity(0.055), radius: 1.5, y: 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)

            // ── 下：新建任务（浅蓝图标底 + 蓝字）──
            Button {
                onNewChat()
                drawerState.close()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("新建任务")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.055), radius: 1.5, y: 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
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

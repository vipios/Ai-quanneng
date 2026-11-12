//
//  SettingsSheet.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  The settings screen presented from the home toolbar: its navigation
//  destinations and the top-level list linking to every settings page.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

// MARK: - Settings Sheet

private enum SettingsDestination: Hashable {
    case providers
    case providerDetail(instanceId: String)
    case modelGroups
    case modelGroupDetail(groupId: String)
    case usage
    case skills
    // [T-ios-assistant-header-open-soul]
    case soul
    // [T-tools-master-switch]
    case tools
    case memory
    case storage
    case mountedFolders
    case sharedFolders
    case logs
    // [T-minis-relay] 设备管理：中转站后台 / 路由器后台
    case relayAdmin
    case relayRouter
    case appearance
    case background
    case about
    case permissions
    case environments
    // [T-mcp-oauth-deeplink]
    case mcpIntegrations
    case mcpServerDetail(serverId: String)
}

struct SettingsSheet: View {
    @Binding var showTerminal: Bool
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            // [R42-换皮] 这一版只换外观，功能一行没动。
            //
            // 原来的 `List` 用的是系统 chrome：分组标题是小号灰字、
            // 行高由系统决定、图标 21pt 圆形。设计稿是另一套度量 ——
            // 图标 29×29 圆角 7.5、行最小 52、标题 17pt、分组标题
            // 13pt/600 且用黑色、卡片圆角 14、左右边距 16。
            //
            // 换成 ScrollView + 自己排的卡片之后，那些数值才落得下来
            // （List 的 row inset / separator inset 是系统接管的，改不干净）。
            // 所有跳转仍然是原来的 `NavigationLink`，目标页面一个没换。
            ScrollView {
                VStack(spacing: 0) {
                    providersSection
                    deviceSection
                    appearanceSection
                    agentSection
                    storageSection
                    permissionsSection
                    logsSection
                    selfUpdateSection
                }
                .padding(.bottom, SettingsDesign.listBottomPadding)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsDestination.self) { dest in
                destinationView(for: dest)
            }
            .onAppear {
                applyPendingDeepLink()
                // Legacy flags — kept so older call sites keep working.
                if deepLink.showEnvironmentVariables {
                    navPath.append(SettingsDestination.environments)
                    deepLink.showEnvironmentVariables = false
                }
                if deepLink.showPermissions {
                    navPath.append(SettingsDestination.permissions)
                    deepLink.showPermissions = false
                }
                // Restore the user's location after a language-change rebuild.
                // AppearanceSettingsView's language picker writes this flag
                // right before flipping `appLanguage`, knowing the root
                // `.id(appLanguage)` will tear the whole tree down. ContentView
                // re-opens the sheet on re-mount; here we push back to the
                // destination so the user lands where they were, now rendered
                // in the new language.
                if let dest = UserDefaults.standard.string(forKey: "pendingSettingsReopen") {
                    UserDefaults.standard.removeObject(forKey: "pendingSettingsReopen")
                    switch dest {
                    case "appearance":
                        navPath.append(SettingsDestination.appearance)
                    default:
                        break
                    }
                }
            }
            .onChange(of: deepLink.pendingSettingsTarget) { _ in
                applyPendingDeepLink()
            }
        }
        .preferredColorScheme(appearanceMode == 1 ? .light : appearanceMode == 2 ? .dark : nil)
        .appFontScale()
    }

    // MARK: - [R42] 分组（外观照设计稿，功能照原版）

    /// 一个分组的标题。设计稿 `#stBody .grp-head`：13pt/600、黑色、
    /// 左缩进 34、上 22 下 8。
    private func groupHeader(_ text: String) -> some View {
        Text(text)
            .font(SettingsDesign.sectionHeaderFont)
            // 设计稿这里用的是 --label（黑），不是系统 List header 的灰色。
            // 这是「一眼像设计稿」最明显的一处差别。
            .foregroundStyle(Color(.label))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, SettingsDesign.sectionHeaderLeading)
            .padding(.trailing, SettingsDesign.cardInset)
            .padding(.top, SettingsDesign.sectionHeaderTop)
            .padding(.bottom, SettingsDesign.sectionHeaderBottom)
    }

    /// 卡片容器。设计稿 `#stBody .card`：白底、左右 16、圆角 14、裁切。
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: SettingsDesign.cardRadius,
                                    style: .continuous))
        .padding(.horizontal, SettingsDesign.cardInset)
    }

    /// 行与行之间的分隔线。
    ///
    /// 设计稿是 `left:56px`（对齐到文字开头），原版 List 的默认 inset 是 16，
    /// 会和图标根部交叉。这里自己画，缩进精确可控。
    private func rowDivider() -> some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
            .padding(.leading, SettingsDesign.separatorInset)
    }

    // MARK: LLM Providers

    private var providersSection: some View {
        VStack(spacing: 0) {
            groupHeader(AppLocalized("LLM Providers"))

            card {
                NavigationLink {
                    ProviderInstancesView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.providers,
                                                        fallback: "Manage Providers")),
                        symbol: "key.fill",
                        iconTint: SettingsDesign.blue
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                // [R65-中转站入口搬进设置]
                // 这个入口原来在「AI 服务商」页右上角加号菜单里（和添加服务商、
                // 导入服务商挤在一个 Menu 里）。用户的要求是：别在那个菜单里
                // 出现，挪到设置页、紧跟在「AI 服务商」下面，图标样式和上面
                // 那一行保持一致。
                //
                // 所以这里用同一套 SettingsRowContent（蓝底圆角方块 + 标题），
                // 而不是菜单里那种纯文字 Label ——「样式对齐」指的就是这个外框。
                // 图形仍用 network：它本来就是中转站在这台机器上的记号，换掉
                // 反而要重新认。
                //
                // [R78-中转站自己管自己] 这一行原来直通「添加 AI 中转站」表单
                // ← 于是用户加完中转站，回到「AI 服务商」才找得到它（中转站
                // 底层就是个 ProviderInstance，天然会混进那边的分组里）。
                // 现在改成进中转站自己的列表页：列表 + 右上角加号，
                // 结构跟「AI 服务商」一模一样，各管各的。
                //
                // 标题沿用原来的 key（「添加 AI 中转站」），不换名字 ——
                // 用户认的就是这一行，改名等于让他重新找一个入口。
                NavigationLink {
                    RelayInstancesView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.addRelay,
                                                        fallback: "Add AI Relay")),
                        symbol: "network",
                        iconTint: SettingsDesign.blue
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                NavigationLink {
                    ModelGroupsView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.modelGroups,
                                                        fallback: "Model Groups")),
                        symbol: "gearshape.fill",
                        iconTint: SettingsDesign.gray
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                NavigationLink {
                    UsageStatsView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.tokenUsage,
                                                        fallback: "Token Usage")),
                        symbol: "chart.line.uptrend.xyaxis",
                        iconTint: SettingsDesign.green
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 设备管理

    private var deviceSection: some View {
        VStack(spacing: 0) {
            groupHeader(AppLocalized("设备管理"))

            card {
                NavigationLink {
                    RelayAdminView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.relayAdmin,
                                                        fallback: "中转站后台")),
                        symbol: "server.rack",
                        iconTint: SettingsDesign.blue,
                        // server.rack 在 17pt 下几乎看不见，单独放大。
                        glyphScale: 1.25
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                NavigationLink {
                    RelayRouterView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.relayRouter,
                                                        fallback: "路由器后台")),
                        symbol: "wifi.router.fill",
                        iconTint: SettingsDesign.green,
                        glyphScale: 1.1
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(spacing: 0) {
            groupHeader(AppLocalized("Appearance"))

            card {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.appearance,
                                                        fallback: "Appearance")),
                        symbol: "paintbrush.fill",
                        iconTint: SettingsDesign.indigo
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Agent Runtime

    private var agentSection: some View {
        VStack(spacing: 0) {
            groupHeader(AppLocalized("Agent Runtime"))

            card {
                NavigationLink {
                    ToolsSettingsView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.agentTools,
                                                        fallback: "Agent Tools")),
                        symbol: "wrench.and.screwdriver.fill",
                        iconTint: SettingsDesign.indigo
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                NavigationLink {
                    HelperSettingsView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.subAgents,
                                                        fallback: "Sub Agents")),
                        symbol: HelperAccent.glyph,
                        iconTint: SettingsDesign.purple
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                NavigationLink {
                    // 「技能」进的是能力域浏览页（20 个域 + 自动路由试用），
                    // 和定制仓一致。
                    //
                    // 之前这里被我改成直达 SkillsManagementView（已装技能
                    // 列表），结果是：内置技能本来只有一个 skill-creator，
                    // 这一页就只有一行，看着像「技能里面是空的」。
                    // 那张列表是「管理已装技能」的工具页，不该当入口。
                    // 管理页的入口在浏览页右上角（square.and.arrow.down）。
                    SkillsCatalogView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.skills,
                                                        fallback: "Skills")),
                        symbol: "puzzlepiece.extension.fill",
                        iconTint: SettingsDesign.blue
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                // [R42] 说话模式。位置对齐设计稿：技能之后、Soul 之前。
                //
                // 默认是「自动」—— 用户不点它也一直按内容自动判，
                // 技能和人格本来就是自动的，这一项跟着三元组走。
                NavigationLink {
                    SpeakModeSettingsView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.modes,
                                                        fallback: "语气")),
                        symbol: "text.bubble.fill",
                        iconTint: SettingsDesign.orange
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                NavigationLink {
                    SoulSettingsView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.soul,
                                                        fallback: "Soul")),
                        symbol: "sparkles",
                        iconTint: SettingsDesign.pink
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                NavigationLink {
                    MemoryManagementView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.memory,
                                                        fallback: "Memory")),
                        symbol: "brain.head.profile",
                        iconTint: SettingsDesign.purple
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                NavigationLink {
                    MCPIntegrationsView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.mcpIntegrations,
                                                        fallback: "MCP Integrations")),
                        symbol: "square.stack.3d.up.fill",
                        iconTint: SettingsDesign.teal
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                NavigationLink {
                    EnvironmentVariablesView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.environmentVars,
                                                        fallback: "Environment Variables")),
                        symbol: "terminal.fill",
                        iconTint: SettingsDesign.black
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        VStack(spacing: 0) {
            groupHeader(AppLocalized("Storage"))

            card {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.storage,
                                                        fallback: "Storage")),
                        symbol: "archivebox.fill",
                        iconTint: SettingsDesign.blue
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                NavigationLink {
                    SharedFoldersSettingsView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.sharedFolders,
                                                        fallback: "Shared Folders")),
                        symbol: "folder.fill",
                        iconTint: SettingsDesign.green
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                NavigationLink {
                    MountedFoldersSettingsView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.mountedFolders,
                                                        fallback: "Mount External Folders")),
                        symbol: "externaldrive.fill.badge.plus",
                        iconTint: SettingsDesign.orange
                    )
                }
                .buttonStyle(.plain)

                if #available(iOS 17.0, *) {
                    rowDivider()

                    NavigationLink {
                        // v2 is the default sync engine; legacy v1
                        // settings page is unreachable from here.
                        CloudSyncSettingsV2View()
                    } label: {
                        SettingsRowContent(
                            title: AnyView(SettingsRowLabel(.iCloudSync,
                                                            fallback: "iCloud Sync")),
                            symbol: "icloud.fill",
                            iconTint: SettingsDesign.cyan
                        )
                    }
                    .buttonStyle(.plain)
                }

                rowDivider()

                NavigationLink {
                    BackupAndRestoreView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.backupRestore,
                                                        fallback: "Backup & Restore")),
                        symbol: "arrow.triangle.2.circlepath",
                        iconTint: SettingsDesign.indigo
                    )
                }
                .buttonStyle(.plain)

                rowDivider()

                NavigationLink {
                    GitHubAccountView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.githubAccount,
                                                        fallback: "GitHub 账号")),
                        symbol: "chevron.left.forwardslash.chevron.right",
                        iconTint: SettingsDesign.black
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(spacing: 0) {
            groupHeader(AppLocalized("Permissions"))

            card {
                NavigationLink {
                    OffloadPermissionSettingsView()
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.permissions,
                                                        fallback: "Permissions")),
                        symbol: "lock.shield.fill",
                        iconTint: SettingsDesign.red
                    )
                }
                .buttonStyle(.plain)

                if BiometricAuth.isAvailable {
                    rowDivider()

                    NavigationLink {
                        FaceIDProtectionSettingsView()
                    } label: {
                        SettingsRowContent(
                            title: AnyView(SettingsRowLabel(
                                .faceID,
                                fallback: "\(BiometricAuth.biometryDisplayName) Protection")),
                            // Match SF Symbol to the device's actual sensor — Touch ID
                            // devices showed a Face ID glyph here before.
                            symbol: BiometricAuth.biometryIconName,
                            iconTint: SettingsDesign.teal
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Logs

    private var logsSection: some View {
        VStack(spacing: 0) {
            groupHeader(AppLocalized("Logs"))

            card {
                NavigationLink {
                    LogManagementView(initialTab: deepLink.pendingLogsTab ?? "logs")
                        .onAppear { deepLink.pendingLogsTab = nil }
                } label: {
                    SettingsRowContent(
                        title: AnyView(SettingsRowLabel(.logs,
                                                        fallback: "Logs")),
                        symbol: "doc.text.fill",
                        iconTint: SettingsDesign.gray
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 版本和更新

    private var selfUpdateSection: some View {
        VStack(spacing: 0) {
            groupHeader(AppLocalized("版本和更新"))
            card {
                SelfUpdateSection()
            }
        }
    }

    // MARK: - 跳转目标（原样保留，一个没改）

    @ViewBuilder
    private func destinationView(for dest: SettingsDestination) -> some View {
        switch dest {
        case .providers:
            ProviderInstancesView()
        case .providerDetail(let id):
            ProviderInstanceDetailView(instanceId: id)
        case .modelGroups:
            ModelGroupsView()
        case .modelGroupDetail(let id):
            ModelGroupDetailView(groupId: id)
        case .usage:
            UsageStatsView()
        case .skills:
            // 与设置首页那一行保持一致：技能 = 能力域浏览页。
            SkillsCatalogView()
        case .soul:
            SoulSettingsView()
        case .tools:
            ToolsSettingsView()
        case .memory:
            MemoryManagementView()
        case .storage:
            StorageManagementView()
        case .mountedFolders:
            MountedFoldersSettingsView()
        case .sharedFolders:
            SharedFoldersSettingsView()
        case .logs:
            // Pull a one-shot tab hint from the deep link router
            // (e.g. `?tab=config-audit`). LogManagementView clears
            // its local state independently; the published value
            // here is consumed once and reset to nil.
            LogManagementView(initialTab: deepLink.pendingLogsTab ?? "logs")
                .onAppear { deepLink.pendingLogsTab = nil }
        case .relayAdmin:
            RelayAdminView()
        case .relayRouter:
            RelayRouterView()
        case .appearance:
            AppearanceSettingsView()
        case .background:
            EnhancedBackgroundSettingsView()
        case .about:
            AboutView()
        case .environments:
            EnvironmentVariablesView()
        case .permissions:
            OffloadPermissionSettingsView()
        // [T-mcp-oauth-deeplink] Detail = the list view told to open
        // the server's edit sheet on appear; a deleted/unknown server
        // just lands on the list (no crash, sensible fallback).
        case .mcpIntegrations:
            MCPIntegrationsView()
        case .mcpServerDetail(let serverId):
            MCPIntegrationsView(initialEditServerId: serverId)
        }
    }


    /// Translate `DeepLinkCoordinator.pendingSettingsTarget` into a
    /// NavigationStack push and clear the pending value. Called from
    /// `onAppear` (cold-start deep link) and `onChange` (deep link
    /// arriving while the sheet is already open).
    ///
    /// `.environments` keeps its existing prefill semantics — the
    /// environments view consumes `pendingEnvVarCreate` separately on
    /// appear, so we only have to navigate here.
    private func applyPendingDeepLink() {
        guard let target = deepLink.pendingSettingsTarget else { return }
        // Reset path so deep links are predictable: a deep link always
        // lands on the requested destination as the only stack entry,
        // not on top of whatever the user was browsing earlier.
        navPath = NavigationPath()
        switch target {
        case .home:
            break // already at Settings root
        case .providers:
            navPath.append(SettingsDestination.providers)
        case .providerDetail(let id):
            navPath.append(SettingsDestination.providers)
            navPath.append(SettingsDestination.providerDetail(instanceId: id))
        case .modelGroups:
            navPath.append(SettingsDestination.modelGroups)
        case .modelGroupDetail(let id):
            navPath.append(SettingsDestination.modelGroups)
            navPath.append(SettingsDestination.modelGroupDetail(groupId: id))
        case .usage:
            navPath.append(SettingsDestination.usage)
        case .skills:
            navPath.append(SettingsDestination.skills)
        case .soul:
            navPath.append(SettingsDestination.soul)
        case .tools:
            navPath.append(SettingsDestination.tools)
        case .memory:
            navPath.append(SettingsDestination.memory)
        case .storage:
            navPath.append(SettingsDestination.storage)
        case .mountedFolders:
            navPath.append(SettingsDestination.mountedFolders)
        case .sharedFolders:
            navPath.append(SettingsDestination.sharedFolders)
        case .logs:
            navPath.append(SettingsDestination.logs)
        case .appearance:
            navPath.append(SettingsDestination.appearance)
        case .background:
            navPath.append(SettingsDestination.background)
        case .about:
            navPath.append(SettingsDestination.about)
        case .permissions:
            navPath.append(SettingsDestination.permissions)
        case .environments:
            navPath.append(SettingsDestination.environments)
        case .mcpIntegrations:
            navPath.append(SettingsDestination.mcpIntegrations)
        case .mcpServerDetail(let id):
            navPath.append(SettingsDestination.mcpServerDetail(serverId: id))
        }
        deepLink.pendingSettingsTarget = nil
    }

    /// Compose the feedback mailto URL with a prefilled body that includes
    /// app version, iOS version, and a machine identifier, plus a prompt
    /// asking the user to attach a screenshot manually (mailto:// can't
    /// auto-attach). Using URLComponents so the subject and body go through
    /// proper URL encoding without hand-rolling addingPercentEncoding calls.
    fileprivate static func makeFeedbackEmailURL() -> URL? {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        let device = machineIdentifier()

        let body = """
        Please describe your feedback:


        ---
        App Version: \(appVersion) (\(build))
        iOS Version: \(iosVersion)
        Device: \(device)

        Screenshot (optional): Please attach a screenshot if relevant.
        """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "dev@openminis.app"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "全能AI Feedback"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    /// Build the GitHub Issue URL with a bilingual bug-report template
    /// pre-filled with platform / OS / app / device info. SwiftUI `Link`
    /// hands the URL to UIApplication.shared.open, which routes to Safari.
    fileprivate static func makeBugReportURL() -> URL? {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        let device = machineIdentifier()

        let body = """
        ## 📝 Problem Summary

        <!-- Briefly describe the issue you encountered -->


        ## 📱 Basic Information

        | Field | Value |
        |-------|-------|
        | Platform | iOS |
        | OS Version | iOS \(iosVersion) |
        | Minis Version | \(appVersion) (build \(build)) |
        | Device Model | \(device) |

        ## 🔁 Steps to Reproduce

        1.
        2.
        3.

        ## ❌ Error Details

        ```
        paste error here
        ```

        ## ✅ Expected Behavior



        ## 🗂️ Additional Information

        """

        // 提 issue 的目标是**我们自己的**仓库，不是原版。
        //
        // 原来这里硬写 github.com/OpenMinis/OpenMinis/issues/new，
        // 那是原版项目的 issue 页。发过去既没人管，也会让用户以为
        // 问题出在原版身上 —— 我们是独立版本线，报告该落在自己的
        // 更新源仓库。没配更新源时返回 nil，调用点会自动隐藏入口。
        guard SelfUpdate.isConfigured else { return nil }
        var components = URLComponents(string: "https://github.com/\(SelfUpdate.repo)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "[Bug] "),
            URLQueryItem(name: "body", value: body),
        ]
        return components?.url
    }

    /// Returns the hardware model identifier, e.g. "iPhone16,2".
    /// `UIDevice.current.model` returns the generic "iPhone" / "iPad" and
    /// isn't useful in a bug report, so we fall back to utsname.
    private static func machineIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        let id = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return id.isEmpty ? UIDevice.current.model : id
    }
}

#Preview {
    ContentView()
}

//
//  RelayInstancesView.swift
//  Minis — 「AI 中转站」列表
//
//  ============================================================
//  为什么需要这一页
//
//  中转站在底层就是一个普通的 `ProviderInstance`（双地址、线路模型全靠
//  旁挂的 `relay-profiles.json` 档案），所以「添加 AI 中转站」保下来的东西
//  会自然出现在「AI 服务商」列表里 —— 而且是按 providerType 分组，混在
//  OpenAI / Anthropic 那些真服务商中间。用户看到的是一条地址对不上、
//  底下还挂着一堆模型的怪条目，根本认不出那是自己刚加的中转站。
//
//  用户的要求是「自己管自己的」：
//    · 中转站只在「AI 中转站」这一页出现，不再进「AI 服务商」；
//    · 这一页右上角也要有一个和「AI 服务商」一样的 `+`。
//
//  过滤在 `ProviderInstancesView` 那边做（用同一份档案集合取快照），
//  这一页只负责「列出来 / 加 / 改 / 删」。
//  ============================================================
//

import SwiftUI

struct RelayInstancesView: View {

    @ObservedObject private var store = ProviderConfigStore.shared

    /// 存档页返回后自增，用来强制重算行。
    ///
    /// 为什么要它：`RelayProfileStore` 刻意不是 `ObservableObject`（它用
    /// NSLock 自管并发，从后台线程也要读），所以「改了档案」不会让 SwiftUI
    /// 重绘。编辑页里如果只改了线路 / 模型（实例本身没动），这一页的
    /// 线路徽标就是旧的。存一次盘就重算一次，用这个整数当触发点。
    @State private var reloadToken = 0

    /// 新建 / 编辑共用同一个 sheet。
    ///
    /// 不用「`showAdd` + `editingId` 两个 sheet」：同一个视图上挂两个
    /// `.sheet`，只有一个能稳定弹出（SwiftUI 的老问题），点了没反应又查不出
    /// 原因。合成一个 item 驱动的 sheet，谁赋值就弹谁。
    @State private var editor: RelayEditorRequest?

    /// 待确认删除的行。删除会带走 API Key 和全部模型条目，必须有确认。
    @State private var pendingDelete: RelayListRow?

    // MARK: - 数据

    /// 一行 = 一个实例 + 它的中转站档案。
    struct RelayListRow: Identifiable {
        let instance: ProviderInstance
        let profile: RelayProviderProfile
        var id: String { instance.id }
    }

    private struct RelayEditorRequest: Identifiable {
        let id = UUID()
        /// nil = 新建；有值 = 编辑那个实例。
        let instanceId: String?
    }

    /// 按实例当前的存储顺序列出，和「AI 服务商」保持同一种排序来源。
    ///
    /// 只在有档案、且实例还在的时候出一行：档案是旁挂的，删实例时
    /// `ProviderConfigStore.removeInstance` 会顺手删档案，但同步冲突
    /// （另一台设备删了、这台还没拉到）之后也可能出现「有档案没实例」，
    /// 那种残档不该渲染成一行空壳。
    private var rows: [RelayListRow] {
        _ = reloadToken   // 让 body 依赖它（档案不是 ObservableObject）
        let profiles = RelayProfileStore.shared.allProfiles()
        guard !profiles.isEmpty else { return [] }
        let byId = Dictionary(store.instances.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        return profiles.compactMap { profile in
            guard let instance = byId[profile.instanceId] else { return nil }
            return RelayListRow(instance: instance, profile: profile)
        }
    }

    /// 当前「新建对话会默认用它」的那个中转站实例 id。
    ///
    /// 判定口径刻意简单：默认组的第一个成员是 `实例id/模型id`，取斜杠
    /// 前那一段。新建对话的解析链（tier=1）就是要一个组，我们给每个
    /// 中转站建的组都是单实例单成员，所以这个反推是准的。
    /// 默认组被别人（比如「模型组」页）改成跨实例的组时这里返回 nil，
    /// 不给任何一行打勾 —— 那时候确实没有「某个中转站是默认」这回事。
    private var defaultInstanceId: String? {
        guard let groupId = store.defaultPrimaryGroupId,
              let group = store.group(for: groupId),
              let first = group.memberEntryIds.first,
              let slash = first.firstIndex(of: "/") else { return nil }
        return String(first[..<slash])
    }

    /// 把这个中转站设成新会话默认。
    ///
    /// 优先用「按当前线路该用的那个模型」建组，与保存中转站时的口径一致；
    /// 对不上时 store 会退到该实例的第一个文本模型，不会静默失败。
    private func makeDefault(_ row: RelayListRow) {
        let preferred = row.profile.modelForRoute(isLan: row.profile.resolvedIsLan())
        store.makeDefaultGroup(for: row.id, preferredModelId: preferred)
    }

    // MARK: - Body

    var body: some View {
        let items = rows
        let defaultId = defaultInstanceId

        return List {
            if items.isEmpty {
                Section {
                    emptyState
                }
            } else {
                Section {
                    ForEach(items) { item in
                        // 整行可点 → 打开编辑页。中转站没有「详情页」这种东西
                        // （它不是一个能选模型、看配额的服务商），直接进编辑
                        // 就是最短路径，少一层壳。
                        Button {
                            editor = RelayEditorRequest(instanceId: item.id)
                        } label: {
                            RelayInstanceRow(
                                row: item,
                                modelCount: store.visibleEntries(for: item.id).count,
                                isSessionDefault: item.id == defaultId
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            // 前滑「设为默认」：新建对话直接用它。
                            // 已经有默认的那一行不再给这个动作 —— 点了也是
                            // 同一个结果，只会在界面上闪一下。
                            if item.id != defaultId {
                                Button {
                                    makeDefault(item)
                                } label: {
                                    Label("设为默认", systemImage: "star.fill")
                                }
                                .tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // 破坏性按钮放最右（平台位置），且不允许全滑 ——
                            // 一次长滑就把中转站连同 Key 删掉太危险。
                            Button(role: .destructive) {
                                pendingDelete = item
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                editor = RelayEditorRequest(instanceId: item.id)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("已添加的中转站")
                } footer: {
                    Text("带「默认」标记的那个，打开新对话时会自动选中它的模型。右滑一行可以换成别的；左滑删除，一次滑到底不会直接删。")
                }
            }
        }
        .navigationTitle("AI 中转站")
        .navigationBarTitleDisplayMode(.inline)
        // 和「AI 服务商」页一样，进页面补一次丢失的档案（换设备 / 恢复备份
        // 之后只剩实例，双地址功能静默失效）。有档案的会被跳过，不是每次写盘。
        .onAppear {
            RelayProfileStore.shared.healMissingProfiles(from: store.instances)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = RelayEditorRequest(instanceId: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("添加 AI 中转站"))
            }
        }
        .sheet(item: $editor, onDismiss: { reloadToken &+= 1 }) { request in
            // AddRelayProviderView 自己带「取消 / 保存」两个 toolbar item，
            // 且保存后走 `dismiss()` —— 它天生就该被 sheet 包着，
            // 所以这里也要套一层 NavigationStack，跟详情页的编辑入口一致。
            NavigationStack {
                AddRelayProviderView(editInstanceId: request.instanceId)
            }
        }
        .alert(
            AppLocalized("Delete Provider"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { row in
            Button("删除", role: .destructive) {
                // removeInstance 会顺手把 relay 档案一起删掉
                // （见 ProviderConfigStore.removeInstance 末尾）。
                store.removeInstance(row.id)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("这将移除该中转站及其全部模型条目，API Key 会从钥匙串中删除。")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("还没有添加中转站")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("点右上角 + 添加一个，填内网和外网两个地址。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - 行

/// 一行的样子：状态点 + 名称 + 线路徽标 + 当前生效地址 + 模型数。
///
/// 和「AI 服务商」的 `InstanceRow` 刻意长得像（同一个状态点、同一个字号
/// 层级），从设置页连进来不会有「换了一套界面」的割裂感。
private struct RelayInstanceRow: View {
    let row: RelayInstancesView.RelayListRow
    let modelCount: Int
    /// 这一行是不是「新建对话会自动用它」的那一个。
    let isSessionDefault: Bool

    private var instance: ProviderInstance { row.instance }
    private var profile: RelayProviderProfile { row.profile }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(instance.isEnabled ? Color.green : Color(UIColor.quaternaryLabel))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(instance.label)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if isSessionDefault {
                        Text("默认")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }

                    routeBadge
                }

                // 当前**生效**的地址（不是内网那个固定值）：
                // 用户想确认「现在这台机器实际在打哪个地址」就看这一行。
                Text(profile.effectiveURL())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(profile.protocolKind.title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if modelCount > 0 {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(AppLocalized("\(modelCount) models"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if !instance.isEnabled {
                Text("已停用")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(UIColor.quaternarySystemFill))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    /// 线路徽标。文字直接用 `routeMode.title`（自动判定 / 只用内网 /
    /// 只用外网），图标跟着走，不另造一套说法 —— 编辑页里用户看到的是
    /// 同一批字，回到列表不会对不上号。
    private var routeBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: profile.routeMode.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(profile.routeMode.title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(profile.resolvedIsLan() ? Color.orange : Color.blue)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(
            (profile.resolvedIsLan() ? Color.orange : Color.blue).opacity(0.12),
            in: Capsule()
        )
    }
}

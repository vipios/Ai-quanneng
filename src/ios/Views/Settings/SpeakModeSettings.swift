//
//  SpeakModeSettings.swift
//  全能AI - 说话模式（R40 模板复刻）
//
//  ============================================================
//  这是 R40 模板「说话风格」页的 SwiftUI 原生复刻。
//  数据来自 RouteCatalogData.ModeCatalog（与 ui.html 的 MODES 一致）。
//
//  结构：7 个模式卡，每张卡 = 图标 + 名称（默认模式带「默认」徽章）
//  + 描述 + 单选圆点。选中状态用蓝色描边高亮。点击卡片选中；
//  点击「查看内容」展开/收起该模式的 detail 详情。
//
//  存储复用 SpeakModeSettings（UserDefaults），与 RouteInjector
//  注入链路的读取保持一致 —— 这里只换 UI，不改判定语义。
//  ============================================================
//

import SwiftUI

// MARK: - 存储（保持原样，供 ModeCatalog 复用）

enum SpeakModeSettings {

    private static let key = "minis.speakMode.selected"

    /// 自动判定的哨兵值。
    static let autoId = "auto"

    static var selected: String {
        get {
            let v = UserDefaults.standard.string(forKey: key) ?? autoId
            if v == autoId { return autoId }
            return RouteMode.names[v] != nil ? v : autoId
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }

    static var isAuto: Bool { selected == autoId }
    static var isPinned: Bool { !isAuto }
}

// MARK: - 设置页

struct SpeakModeSettingsView: View {

    @State private var selected: String = SpeakModeSettings.selected
    @State private var expandedDetail: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(ModeCatalog.all) { mode in
                    modeCard(mode)
                }

                Text("模式决定 AI 用什么口径回答、默认先走哪条动作链。选哪个都能把活干完，区别只在出手方式和详略。改完立刻生效，下一次对话就按新模式说话。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 26)
                    .lineSpacing(2)
            }
            .padding(.top, 10)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("说话风格")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 模式卡

    private func modeCard(_ mode: ModeCatalogItem) -> some View {
        let isOn = selected == mode.id
        let isExpanded = expandedDetail.contains(mode.id)

        return VStack(alignment: .leading, spacing: 0) {
            // 顶部：图标 + 名称/徽章 + 描述 + 单选圆点
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(mode.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isOn ? SettingsDesign.blue : Color(.label))
                        if mode.isDefault {
                            Text("默认")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(SettingsDesign.blue)
                                .clipShape(Capsule())
                        }
                    }
                    Text(mode.desc)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineSpacing(1.5)
                        .padding(.top, 1)
                }

                Spacer(minLength: 0)

                // 单选圆点
                ZStack {
                    Circle()
                        .stroke(isOn ? SettingsDesign.blue : Color(.systemGray3), lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    if isOn {
                        Circle()
                            .fill(SettingsDesign.blue)
                            .frame(width: 12, height: 12)
                    }
                }
                .padding(.top, 2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selected = mode.id
                SpeakModeSettings.selected = mode.id
            }

            // 「查看内容」展开按钮
            Button {
                if isExpanded {
                    expandedDetail.remove(mode.id)
                } else {
                    expandedDetail.insert(mode.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SettingsDesign.blue)
                    Text(isExpanded ? "收起内容" : "查看内容")
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsDesign.blue)
                }
                .padding(.top, 9)
            }
            .buttonStyle(.plain)

            // 展开的详情
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(mode.detail.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.0)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, alignment: .leading)
                            Text(entry.1)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color(.label))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 9)
                .padding(.leading, 44)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isOn ? SettingsDesign.blue.opacity(0.04) : Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isOn ? SettingsDesign.blue : Color.clear, lineWidth: 1.5)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 9)
    }
}

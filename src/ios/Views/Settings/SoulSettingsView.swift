//
//  SoulSettingsView.swift
//  全能AI - 人格页（R40 模板复刻）
//
//  ============================================================
//  这是 R40 模板「人格」全屏页的 SwiftUI 原生复刻。
//  数据来自 RouteCatalogData.PersonaCatalog（与 ui.html 的 PERSONAS 一致）。
//
//  结构（自上而下，与预览图一致）：
//    1. 搜索框：搜索人格、能力或场景
//    2. 人格选择：按分类分组（自动/逆向/执行/规则），每张卡 =
//       左侧色条 + 名称 + 副标题 + 选中徽章/单选圆点 + 摘要 + 标签
//    3. 当前生效：当前人格卡（图标 + 名称 + meta + 「已启用」徽章 + 摘要）
//    4. 大纲：当前人格的 fragments 列表（序号 + 标题 + 简述）
//    5. 我的补充：多行输入框，每轮追加在人格之后
//
//  原 SoulSettingsView（编辑 SOUL.md 的 Form）已不再作为本页展示，
//  但 SOUL.md 的读写逻辑（SoulStore）保持不变，人格选择只是前端
//  展示 + 记录选择，实际注入仍走 RouteInjector 的三元组。
//  ============================================================
//

import SwiftUI

struct SoulSettingsView: View {

    @State private var query: String = ""
    @State private var selectedId: String = PersonaCatalog.selectedId
    @State private var supplement: String = PersonaSupplement.text

    private static let maxSupplementLength = 1000

    // 当前人格（id 失效时回落自动路由）。
    private var current: PersonaCatalogItem {
        PersonaCatalog.all.first(where: { $0.id == selectedId }) ?? PersonaCatalog.all[0]
    }

    // 过滤后的分组。
    private var grouped: [(category: PersonaCategory, items: [PersonaCatalogItem])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return PersonaCatalog.categories.compactMap { cat in
            let items = PersonaCatalog.all.filter { p in
                guard p.category == cat.id else { return false }
                if q.isEmpty { return true }
                return (p.name + p.sub + p.summary + p.tags.joined()).lowercased().contains(q)
            }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                // ── 身份（头像 / 名字 / 风格 / 语言）──
                // 原版 SoulSettingsView 的这四项人格页没有，补在最上面一行。
                // 人格正文不在这里摆 —— 人格页的 8 套正文更强，再放一个
                // 2000 token 的编辑器只会让人不知道哪份在生效。
                SoulIdentityCard()

                searchBar

                // ── 人格选择 ──
                if grouped.isEmpty {
                    emptyState
                } else {
                    ForEach(grouped, id: \.category.id) { group in
                        categoryHeader(group.category)
                        ForEach(group.items) { persona in
                            personaCard(persona)
                        }
                    }
                }

                // ── 当前生效 ──
                currentCard

                // ── 大纲 ──
                outlineSection

                // ── 我的补充 ──
                supplementSection
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("人格")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Color(red: 0x8E/255, green: 0x8E/255, blue: 0x93/255))
            TextField("搜索人格、能力或场景", text: $query)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - 分类头

    private func categoryHeader(_ cat: PersonaCategory) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(cat.tint)
                .frame(width: 7, height: 7)
            Text(cat.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 7)
    }

    // MARK: - 人格卡

    private func personaCard(_ persona: PersonaCatalogItem) -> some View {
        let isOn = selectedId == persona.id

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(persona.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isOn ? SettingsDesign.blue : Color(.label))
                    Text(persona.sub)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if isOn {
                    Text("已启用")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(SettingsDesign.blue)
                        .clipShape(Capsule())
                } else {
                    Circle()
                        .stroke(Color(.systemGray3), lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                        .padding(.top, 2)
                }
            }

            Text(persona.summary)
                .font(.system(size: 13))
                .foregroundStyle(isOn ? Color(red: 0x5B/255, green: 0x64/255, blue: 0x72/255) : Color(.secondaryLabel))
                .lineSpacing(2)
                .lineLimit(3)
                .padding(.top, 7)

            HStack(spacing: 5) {
                ForEach(persona.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isOn ? SettingsDesign.blue : Color(.secondaryLabel))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(
                            isOn ? SettingsDesign.blue.opacity(0.09) : Color(.tertiarySystemFill)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .padding(.top, 9)
        }
        .padding(.horizontal, 17)
        .padding(.top, 13)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isOn ? SettingsDesign.blue.opacity(0.04) : Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(alignment: .leading) {
            // 左侧色条
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint(for: persona))
                .frame(width: 3.5)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isOn ? SettingsDesign.blue : Color.clear, lineWidth: 1.5)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedId = persona.id
            PersonaCatalog.selectedId = persona.id
        }
    }

    /// 人格卡的左侧色条颜色（按分类取色，与 ui.html 的 pcard-bar 对应）。
    private func tint(for persona: PersonaCatalogItem) -> Color {
        switch persona.category {
        case "auto": return SettingsDesign.blue
        case "rev":  return SettingsDesign.indigo
        case "jail": return SettingsDesign.red
        case "rule": return SettingsDesign.orange
        default:     return SettingsDesign.gray
        }
    }

    // MARK: - 当前生效

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("当前生效")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 7)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(SettingsDesign.pink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(current.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(.label))
                        Text(current.sub)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color(.secondaryLabel))
                    }

                    Spacer(minLength: 0)

                    Text("已启用")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(SettingsDesign.green)
                        .clipShape(Capsule())
                }

                Text(current.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineSpacing(2.5)
                    .padding(.top, 12)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 大纲

    private var outlineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("大纲")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 7)

            VStack(spacing: 0) {
                ForEach(Array(current.fragments.enumerated()), id: \.element.id) { idx, frag in
                    HStack(alignment: .top, spacing: 10) {
                        Text(frag.index)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(.tertiaryLabel))
                            .frame(width: 20, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(frag.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(.label))
                            Text(frag.summary)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(.secondaryLabel))
                                .lineSpacing(1.5)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    if idx < current.fragments.count - 1 {
                        Rectangle()
                            .fill(Color(.separator))
                            .frame(height: 0.5)
                            .padding(.leading, 44)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 我的补充

    private var supplementSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("我的补充（每轮追加在人格之后）")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 7)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $supplement)
                    .font(.system(size: 14))
                    .frame(minHeight: 88)
                    .scrollContentBackground(.hidden)
                    .onChange(of: supplement) { _ in
                        if supplement.count > Self.maxSupplementLength {
                            supplement = String(supplement.prefix(Self.maxSupplementLength))
                        }
                        PersonaSupplement.text = supplement
                    }
                if supplement.isEmpty {
                    Text("写什么就生效什么，越具体越管用…")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)

            Text("\(supplement.count) / \(Self.maxSupplementLength)")
                .font(.system(size: 11.5))
                .foregroundStyle(Color(.tertiaryLabel))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 24)
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("没找到匹配的人格")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

// MARK: - 「我的补充」存储

/// 「我的补充」文本的持久化（UserDefaults，与 ui.html 的 soul-ta 对应）。
enum PersonaSupplement {
    private static let key = "minis.persona.supplement"

    static var text: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

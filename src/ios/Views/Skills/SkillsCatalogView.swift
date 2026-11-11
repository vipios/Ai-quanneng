//
//  SkillsCatalogView.swift
//  全能AI - 技能页（R40 模板复刻）
//
//  ============================================================
//  这是 R40 模板「技能」全屏页的 SwiftUI 原生复刻。
//  数据来自 RouteCatalogData.DomainCatalog（与 ui.html 的 DOMAINS 一致）。
//
//  结构（自上而下，与预览图一致）：
//    1. 深色英雄卡：大数字「20」+「个能力域」+ 一句说明
//    2. 搜索框：搜技能名、能力或触发词
//    3. 自动路由试用块：打一句话看判到哪个域（走 RouteEngine.decide）
//    4. 分类筛选 chips：横向滚动
//    5. 技能列表：按分类分组，每组「分类色点 + 分类名 + 计数」，
//       下面每个域一行「色点 + 域名 + 描述」
//
//  刻意不做的事：这里只做浏览和「自动路由试用」，不做技能的
//  导入/删除/开关 —— 那些在原 SkillsManagementView 里，功能不变，
//  只是本页换成了 R40 的浏览形态。
//  ============================================================
//

import SwiftUI

struct SkillsCatalogView: View {

    @State private var query: String = ""
    @State private var selectedCategory: String = ""   // 空 = 全部
    @State private var probeText: String = ""
    @State private var probe: RouteDecision?

    // 自动路由试用的示例句，覆盖「强信号 / 多域竞争 / 泛化兜底」。
    private static let rtSamples = [
        "帮我破解这个 ipa 的 dylib",
        "这个 pwn 题有堆溢出，怎么打",
        "sql 注入怎么绕 waf",
        "路由器内存不够了",
        "这次渗透要出报告，怎么定级",
        "写个 python 脚本",
    ]

    // 过滤 + 分组后的数据。
    private var grouped: [(category: DomainCategory, items: [DomainCatalogItem])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = DomainCatalog.all.filter { item in
            if selectedCategory.isEmpty || item.category == selectedCategory { return true }
            return false
        }.filter { item in
            if q.isEmpty { return true }
            return item.name.lowercased().contains(q) || item.detail.lowercased().contains(q)
        }
        return DomainCatalog.categories.compactMap { cat in
            let items = base.filter { $0.category == cat.name }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                heroCard
                searchBar
                routeProbeBox
                categoryChips

                if grouped.isEmpty {
                    emptyState
                } else {
                    ForEach(grouped, id: \.category.id) { group in
                        categoryHeader(group.category, count: group.items.count)
                        ForEach(group.items) { item in
                            domainRow(item, tint: group.category.tint)
                        }
                    }
                }

                footerNote
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("技能")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SkillsManagementView()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
        }
    }

    // MARK: - 英雄卡

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(DomainCatalog.count)")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("个能力域")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.top, 5)
            Text("全部装在本机，AI 按需读取，不占每轮上下文。")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.top, 11)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0x1C/255, green: 0x1C/255, blue: 0x1E/255),
                    Color(red: 0x2C/255, green: 0x2C/255, blue: 0x2E/255),
                    Color(red: 0x3A/255, green: 0x3A/255, blue: 0x3C/255),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Color(red: 0x8E/255, green: 0x8E/255, blue: 0x93/255))
            TextField("搜技能名、能力或触发词", text: $query)
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

    // MARK: - 自动路由试用

    private var routeProbeBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("自动路由试用")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(uiColor: .label))
                Spacer()
                Text("打一句话，看它自己判到哪")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)

            TextField("例如：帮我破解这个 ipa 的 dylib", text: $probeText)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: probeText) { _ in
                    let t = probeText.trimmingCharacters(in: .whitespacesAndNewlines)
                    probe = t.isEmpty ? nil : RouteEngine.decide(t)
                }

            // 判定结果
            if let p = probe {
                HStack(spacing: 6) {
                    Text(p.line)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(uiColor: .label))
                    if p.hit.isEmpty {
                        Text("· 泛化口径")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("· 命中「\(p.hit)」")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 示例句 chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.rtSamples, id: \.self) { s in
                        Button {
                            probeText = s
                            probe = RouteEngine.decide(s)
                        } label: {
                            Text(s)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(uiColor: .label))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color(uiColor: .tertiarySystemFill))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 10)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    // MARK: - 分类筛选 chips

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                chip("全部", count: DomainCatalog.count, isOn: selectedCategory.isEmpty) {
                    selectedCategory = ""
                }
                ForEach(DomainCatalog.categories) { cat in
                    let n = DomainCatalog.all.filter { $0.category == cat.name }.count
                    chip(cat.name, count: n, isOn: selectedCategory == cat.name) {
                        selectedCategory = (selectedCategory == cat.name) ? "" : cat.name
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func chip(_ label: String, count: Int, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(isOn ? .white : Color(uiColor: .label))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isOn ? SettingsDesign.blue : Color(uiColor: .secondarySystemGroupedBackground)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分类头

    private func categoryHeader(_ cat: DomainCategory, count: Int) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(cat.tint)
                .frame(width: 7, height: 7)
            Text(cat.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
            Spacer()
            Text("\(count) 个域")
                .font(.system(size: 11.5))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 7)
    }

    // MARK: - 域行

    private func domainRow(_ item: DomainCatalogItem, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint.opacity(0.75))
                .frame(width: 6, height: 6)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Color(uiColor: .label))
                Text(item.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineSpacing(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 0.5)
                .padding(.leading, 32)
        }
    }

    // MARK: - 空态与页脚

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("没找到匹配的能力域")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footerNote: some View {
        Text("257 个原技能已合并成这一个：空壳与重复项已删，40 份完整方法论原文留在 references/deep/，按需读取。")
            .font(.system(size: 12))
            .foregroundStyle(Color(uiColor: .tertiaryLabel))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .lineSpacing(2)
    }
}

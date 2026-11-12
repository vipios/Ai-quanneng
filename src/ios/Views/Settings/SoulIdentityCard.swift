//
//  SoulIdentityCard.swift
//  全能AI - 人格页顶部身份卡
//
//  ============================================================
//  这个文件补的是「原版 SOUL.md 编辑能力」里**人格页覆盖不到**的那部分。
//
//  背景（别再问一遍为什么拆出来）：
//    上一轮移植把原 SoulSettingsView（编辑 SOUL.md 的 Form）整页替换成了
//    人格选择页。人格页管的是「这套活用什么性子说话」，它覆盖了人格正文
//    （body）那一栏，但**名字 / 头像 / 风格 / 语言这四项它完全不管**：
//
//      · name  —— system prompt 里 `You are {name}, ...` 的 {name}，
//                  以及聊天气泡头部的显示名。人格页没有这一项。
//      · icon  —— 气泡、Live Activity、侧边栏那个图标。
//                  人格页没有这一项。
//      · style —— 硬约束回复语气（如「简洁不废话」）。会覆盖「跟随用户
//                  语言」的默认规则，人格页做不到。
//      · lang  —— 自动 / 中文 / 英文。
//
//    body（人格正文）**故意不做**：人格页的 8 套正文更强（3KB~19KB，
//    不走 SOUL 的 2000 token 上限），这里再摆一个 2000 token 的编辑器
//    只会让用户不知道哪份在生效。
//
//  ============================================================
//  三条纪律：
//
//    1. **不改人格页的既有布局。** 本文件是独立 View，由 SoulSettingsView
//       在 searchBar 之上插一行调用。原有分区、卡片、间距一个不动。
//
//    2. **保存复用 SoulStore，不自己写文件。** 读 `SoulStore.load()`，
//       写 `SoulStore.save()`。icon 的 sidecar（SOUL.icon.png）拆分、同步、
//       缓存刷新全部由 SoulStore 负责，这里只管把 4 个字段凑成 SoulFile。
//
//    3. **body 原样透传。** 保存时把从磁盘读到的 body 原封不动写回去，
//       绝不因为「这个页面不管 body」就把用户的人格正文清空。
//
//  ============================================================
//

import SwiftUI
import PhotosUI

// MARK: - 身份卡

struct SoulIdentityCard: View {

    /// 磁盘上的完整文件。body 只读透传，不在此页展示。
    @State private var loaded: SoulFile = SoulFile(metadata: .default, body: "")

    @State private var name: String = ""
    @State private var style: String = ""
    @State private var lang: String = SoulMetadata.default.lang
    @State private var icon: String = ""

    @State private var showIconOptions = false
    @State private var showEmojiPrompt = false
    @State private var emojiDraft = ""
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var errorText: String?
    @State private var savedFlash = false
    @State private var didLoad = false

    private static var langOptions: [(label: String, value: String)] {
        [
            ("自动", "auto"),
            ("中文", "zh"),
            ("英文", "en"),
        ]
    }

    /// 有改动才写盘。逐字段比较，避免每次输入都触发一次同步记录。
    private var isDirty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != loaded.metadata.name
            || style != loaded.metadata.style
            || lang != loaded.metadata.lang
            || icon != loaded.metadata.icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // ── 身份：头像 + 名字 + 风格 ──
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    iconButton
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("名字", text: $name)
                            .font(.system(size: 16, weight: .semibold))
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                        TextField("风格（例如：简洁、直接、不废话）", text: $style)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                divider

                // ── 语言 ──
                HStack {
                    Text("回复语言")
                        .font(.system(size: 14))
                    Spacer()
                    Picker("", selection: $lang) {
                        ForEach(Self.langOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: lang) { _ in save() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .padding(.horizontal, 16)

            if let e = errorText {
                Text(e)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: name) { _ in scheduleSave() }
        .onChange(of: style) { _ in scheduleSave() }
        .confirmationDialog("更换头像", isPresented: $showIconOptions) {
            Button("选一个 emoji…") {
                emojiDraft = (icon.isEmpty || SoulIconImage.isDataURI(icon)) ? "" : icon
                showEmojiPrompt = true
            }
            Button("选一张图片…") { showPhotoPicker = true }
            if !icon.isEmpty {
                Button("用回默认", role: .destructive) {
                    icon = ""
                    save()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("任何图片都行，会裁成方形并做圆角。")
        }
        .alert("输入一个 emoji", isPresented: $showEmojiPrompt) {
            TextField("✨", text: $emojiDraft)
            Button("取消", role: .cancel) {}
            Button("确定") {
                icon = emojiDraft
                save()
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _ in
            guard let item = photoItem else { return }
            Task { await adoptPhoto(item) }
        }
    }

    // MARK: - 小件

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(SettingsDesign.blue)
                .frame(width: 7, height: 7)
            Text("身份")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))
            Spacer()
            if savedFlash {
                Text("已保存")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsDesign.green)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 7)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
            .padding(.leading, 14)
    }

    private var iconButton: some View {
        Button {
            showIconOptions = true
        } label: {
            SoulIconView(icon: icon, size: 40)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
                .overlay(
                    Circle().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.accentColor))
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                        .offset(x: 1, y: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更换头像")
    }

    // MARK: - 数据

    private func reload() {
        let f = SoulStore.load() ?? SoulFile(metadata: .default, body: "")
        loaded = f
        name = f.metadata.name
        style = f.metadata.style
        lang = f.metadata.lang.isEmpty ? "auto" : f.metadata.lang
        icon = f.metadata.icon
        errorText = nil
        didLoad = true
    }

    /// 输入时防抖保存。名字逐字输入不该每次都写一次盘 —— 会刷爆同步记录。
    private func scheduleSave() {
        guard didLoad else { return }
        SoulIdentitySaver.debounce { save() }
    }

    private func save() {
        guard didLoad else { return }
        // body 原样透传：这个页面不管人格正文，绝不能把它写空。
        let file = SoulFile(
            metadata: SoulMetadata(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                emoji: loaded.metadata.emoji,   // 旧文件里的 emoji 原样留着
                style: style,
                lang: lang,
                icon: icon
            ),
            body: loaded.body
        )
        do {
            try SoulStore.save(file)
            loaded = file
            errorText = nil
            withAnimation { savedFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation { savedFlash = false }
            }
        } catch {
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func adoptPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorText = "这张图片读不出来。"
                return
            }
            // SoulIconImage.encode 收 UIImage、返回 Result —— 裁方形、缩放、
            // 转 PNG 全在它里面做，这里不重复实现。
            switch SoulIconImage.encode(image) {
            case .success(let uri):
                icon = uri
                photoItem = nil
                save()
            case .failure:
                errorText = "这张图片处理失败，换一张试试。"
            }
        } catch {
            errorText = "读取图片失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 防抖保存

/// 名字/风格是逐字符输入的，直接每次按键都写盘会刷爆 iCloud 同步记录
/// （每次 save 都会重写 SOUL.md 并标脏）。这里做 0.6 秒静默期：
/// 连续输入只落最后一次。
///
/// 用 Task + try? await Task.sleep 而不是 DispatchWorkItem：前者天然
/// 支持取消（cancel 后 sleep 立刻抛错），也不需要在闭包里做
/// assumeIsolated 那种容易踩坑的 actor 断言。
@MainActor
enum SoulIdentitySaver {
    private static var pending: Task<Void, Never>?

    static func debounce(_ action: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)   // 0.6s
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

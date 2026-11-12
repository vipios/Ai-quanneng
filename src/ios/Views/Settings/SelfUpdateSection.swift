//
//  SelfUpdateSection.swift
//  Minis — 设置页「版本和更新」区
//
//  ============================================================
//  [R40-更新两处删除] 这一版照着用户 2026-11-10 18:52 的截图改了两处
//
//  ① 删掉「检查更新」右边那枚「未配置」徽标。
//  ② 删掉「更新源」整行。
//
//  合起来是一件事：更新源已经内置（`SelfUpdate.builtinRepo`），
//  用户不需要知道它的存在，也就不需要有「配置它」的位置和
//  「还没配置」的提示。
//
//  第三件事不是删除而是改造：「检查更新」点下去现在会
//  自动测速 → 挑最快的线路 → 自动下载，不再停在「发现新版本」。
//  进度和结果都落在原来那个徽标的位置上，不新增一行。
//
//  ============================================================
//  [R44-下载完弹分享] 用户 2026-11-10 21:44 的原话：
//  「下载完更新文件后要出来弹窗，弹窗里面有苹果共享的那个界面，
//    可以分享到任意 app」
//
//  原来的做法是下载完只在列表里多出一行「安装已下载的包」，点它弹一个
//  **纯文字说明**（「文件在 文件 App → 全能AI → Updates 里…」）。
//  等于让用户自己去找文件、自己想办法打开 —— 这一步本来就是多余的。
//
//  现在：下完之后自动弹系统共享面板（UIActivityViewController），
//  里面就是 iOS 那套「共享到任意 App」：TrollStore、全能签、文件、
//  AirDrop、微信……用户点哪个就是哪个。
//
//  ⚠️ 两处刻意不用的东西：
//   ① 不用 `MinisShareSheet`。它为了绕开 Catalyst 的一个 ShareKit 崩溃，
//      会把「扩展名解析不出 UTI」的文件**复制成 .bin** 再分享。
//      .ipa 正好就是解析不出的那一类 —— 复制成 .bin 之后 TrollStore /
//      全能签都认不出来了，分享等于白做。这里直接给原文件。
//   ② 不做「先弹个确认框再弹分享」。用户要的就是「下载完 → 弹出来」，
//      中间再插一层是把动作推回去一次。
//  ============================================================

import SwiftUI
import UIKit

struct SelfUpdateSection: View {

    // 检查 / 下载状态。nil = 还没查过
    @State private var result: SelfUpdateResult?
    @State private var checking = false
    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var totalBytes: Int64 = 0
    /// [R82] 「换线路」那句提示。只在自动换线时出现，有字节进来就收掉。
    @State private var lineNote = ""
    // [R81-下载进度条] 下面三个只为一个目的：把「还要多久」算给用户看。
    // 光有一个百分比，80MB 下两分钟里数字爬得很慢，看着像卡住了。
    @State private var speedBytesPerSec: Double = 0
    @State private var lastTickAt: Date?
    @State private var lastTickBytes: Double = 0
    @State private var savedFile: URL?
    /// [R44] 下完之后要弹的系统共享面板。非 nil 就 present。
    ///
    /// 用 `.sheet(item:)` 而不是 `.sheet(isPresented:)` + 另一个 @State：
    /// 那样在「置 nil 关闭」和「置 URL 打开」之间会有一次
    /// nil → nil 的中间态，快速连点两次会闪一下。item 只有一个真值源。
    @State private var shareItem: ShareItem?

    var body: some View {
        // [R42-换皮] 从 `Section` 改成纯 VStack。
        //
        // 原来这个视图是塞在 `List { Section { ... } }` 里的：分组标题由
        // Section 的 header 画，行间分隔线由 List 画。现在设置页整体
        // 换成了设计稿的卡片样式（ScrollView + 自绘卡片），List 那套
        // chrome 不存在了 —— `Section` 在 ScrollView 里只会渲染成一个
        // 带系统标题的块，行间也没有分隔线，看起来像散架。
        //
        // 所以这里自己排：两行 + 分隔线 + 结果文字，外层由 SettingsSheet
        // 的 `card {}` 提供白底和圆角。功能一行没动。
        VStack(spacing: 0) {
            // ── 版本 ──
            // 副标题也一并去掉：用户要求这一组不许有小字。
            // 版本号本身已经说明一切，再写「自有版本线」只是噪音。
            SettingsRowContent(
                title: AnyView(SettingsRowLabel(.version, fallback: "版本")),
                symbol: "shippingbox.fill",
                iconTint: SettingsDesign.indigo
            )
            .overlay(alignment: .trailing) {
                Text(SelfUpdate.displayVersion)
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(Color(.secondaryLabel))
                    // 行尾右侧留出 16 的边距（设计稿 .row-val 就是贴在
                    // 行内右边 16 上）。不用 HStack 的 Spacer 是因为
                    // SettingsRowContent 已经占满整行宽度。
                    .padding(.trailing, SettingsDesign.rowPaddingH)
            }

            divider

            // ── 检查更新 ──
            // 点一下就把整条流程跑完：测速 → 比版本 → 有新版就下载。
            Button {
                Task { await runCheckAndDownload() }
            } label: {
                SettingsRowContent(
                    title: AnyView(SettingsRowLabel(.checkUpdate, fallback: "检查更新")),
                    symbol: "arrow.triangle.2.circlepath",
                    iconTint: SettingsDesign.green
                )
                .overlay(alignment: .trailing) {
                    trailingStatus
                        .padding(.trailing, SettingsDesign.rowPaddingH)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(checking || downloading)

            // 结果一句话。只在有话说的时候出现 ——
            // 常驻一行「点上面检查」是多余的，那一行标题已经写清楚了。
            //
            // [R81] 下载中改成显示进度条：原来这里显示的是「有新版 1.27 ·
            // 线路 …」，配上行尾那个 mini 转圈，用户的原话是
            // 「没有进度条，不知道下到多少」—— 80MB 的包，行尾那点小字
            // 根本看不出在走。现在下载期间这一块换成横条 + 已下/总量/速度/剩余。
            if downloading {
                downloadProgressBlock
            } else if !checking, let r = result {
                Text(r.message)
                    .font(SettingsDesign.subFont)
                    .foregroundStyle(color(for: r))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsDesign.separatorInset)
                    .padding(.trailing, SettingsDesign.rowPaddingH)
                    .padding(.bottom, 10)
            }

            // 下载完成后还留一个入口，方便「关掉分享面板之后又想分享」。
            //
            // 为什么不自动装：iOS 的应用安装必须经过系统确认，App 自己
            // 不能静默替换自己（TrollStore 环境也一样，得用户点一下）。
            // 所以这里做的是「把包递到用户手上」—— 点开就是系统共享面板，
            // 选 TrollStore / 全能签 就装了。上一版这里是弹一段纯文字
            // 告诉用户「自己去文件 App 找」，那等于把活推回去。
            if let f = savedFile {
                divider
                Button {
                    shareItem = ShareItem(url: f)
                } label: {
                    HStack(spacing: SettingsDesign.rowGap) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: SettingsDesign.iconGlyph, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: SettingsDesign.iconSize,
                                   height: SettingsDesign.iconSize)
                            .background(SettingsDesign.blue,
                                        in: RoundedRectangle(cornerRadius: SettingsDesign.iconRadius,
                                                             style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("分享 / 安装这个包")
                                .font(SettingsDesign.titleFont)
                                .foregroundStyle(Color(.label))
                            Text(f.lastPathComponent)
                                .font(SettingsDesign.subFont)
                                .foregroundStyle(Color(.secondaryLabel))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, SettingsDesign.rowPaddingH)
                    .padding(.vertical, SettingsDesign.rowPaddingV)
                    .frame(minHeight: SettingsDesign.rowMinHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // [R44] 下完自动弹系统共享面板。系统那套「共享到任意 App」，
        // 不自己造轮子、不筛应用列表。
        .sheet(item: $shareItem) { item in
            IPAShareSheet(url: item.url)
        }
    }

    /// 行间分隔线。缩进对齐文字开头（设计稿 `left:56px`）。
    private var divider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
            .padding(.leading, SettingsDesign.separatorInset)
    }

    // MARK: - 右侧状态

    @ViewBuilder
    private var trailingStatus: some View {
        if downloading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(percentText)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else if checking {
            // 「测速中」而不是「检查中」：这次真的在测全部线路的下载速度，
            // 文案跟着实际动作走。
            //
            // [R59] 池子扩到 11 条之后，这一步最长会花十几秒（每条线路
            // 拉 256KB 实测、单条上限 12 秒，并发跑取最慢那条的时间）。
            // 文案带个「11 条」，用户能明白为什么比之前慢一点 ——
            // 之前是「4 条里挑一个能连的」，现在是「11 条里挑最快的那条」。
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("测速中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let r = result {
            updateBadge(r)
        } else {
            // [R40-删未配置] 这里原来是写死的「未配置」灰徽标。
            // 没有结果时什么都不画 —— 空白比一个假状态干净。
            EmptyView()
        }
    }

    private var percentText: String {
        // [R55] progress < 0 表示「在下载但不知道总量」，别显示 0%。
        if progress < 0 { return "下载中…" }
        let mb = Double(totalBytes) / 1_048_576
        if mb < 0.1 { return "\(Int(progress * 100))%" }
        return "\(Int(progress * 100))%  \(String(format: "%.0f", mb))MB"
    }

    // MARK: - 下载进度块  [R81]

    /// 下载中的进度条。
    ///
    /// 为什么要有：原来整个下载过程只有「检查更新」行尾一个 `mini` 转圈
    /// 加一行 `caption2` 的百分比。80MB 的包在手机上要一两分钟，那点
    /// 尺寸和字号几乎看不出在动 —— 用户的原话是「没有进度条，不知道
    /// 下载到多少」。
    ///
    /// 这里给的是：一条横向进度条 + 百分比 + 「已下 / 总量」+ 实时速度 +
    /// 剩余时间。速度不是装饰，它决定用户要不要继续等 —— 13KB/s 和
    /// 580KB/s 在同一个百分比下是完全不同的处境。
    @ViewBuilder
    private var downloadProgressBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            // [R82] 自动换线时先说明一句，否则进度归零看着像重头开始。
            if !lineNote.isEmpty {
                Text(lineNote)
                    .font(.caption2)
                    .foregroundStyle(Color(.secondaryLabel))
            }
            if progress >= 0 {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(SettingsDesign.green)
            } else {
                // 不知道总量（服务器没给 Content-Length，且 release 里也没
                // 记 size）。别画一条永远 0% 的空轨道 —— 那种「看起来卡住」
                // 的观感正是这次要修的东西，改用不确定态的圆环。
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("下载中…")
                        .font(.caption2)
                        .foregroundStyle(Color(.secondaryLabel))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Text(progress >= 0 ? "\(Int(progress * 100))%" : "下载中…")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color(.label))

                Spacer(minLength: 0)

                Text(progressDetail)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, SettingsDesign.rowPaddingH)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    /// 「34 / 77 MB · 1.2 MB/s · 剩 36 秒」。缺什么就少写什么，不补 0。
    private var progressDetail: String {
        var parts: [String] = []

        if totalBytes > 0, progress >= 0 {
            let done = progress * Double(totalBytes)
            parts.append("\(String(format: "%.0f", done / 1_048_576)) / \(String(format: "%.0f", Double(totalBytes) / 1_048_576)) MB")
        }

        if speedBytesPerSec > 0 {
            parts.append("\(String(format: "%.1f", speedBytesPerSec / 1_048_576)) MB/s")
        }

        if let eta = remainingSecondsText {
            parts.append("剩 \(eta)")
        }

        return parts.joined(separator: " · ")
    }

    /// 剩余时间。只在进度真的动了以后才算 —— 第一个采样点没有速度，
    /// 硬算会得出一个荒谬的数字。
    private var remainingSecondsText: String? {
        guard progress > 0.02, progress < 1,
              speedBytesPerSec > 1, totalBytes > 0 else { return nil }
        let remaining = Double(totalBytes) * (1 - progress) / speedBytesPerSec
        guard remaining.isFinite, remaining > 0, remaining < 3600 else { return nil }
        if remaining < 60 { return "\(Int(remaining.rounded())) 秒" }
        return "\(Int((remaining / 60).rounded())) 分"
    }

    /// 用相邻两次回调的字节差算瞬时速度，再做一次指数平滑。
    ///
    /// 为什么不平滑直接用瞬时值：进度回调的间隔并不均匀（有时 100ms 一次、
    /// 有时 1s 一次），原始值会在 0.2~8 MB/s 之间乱跳，看着像坏了。
    /// 0.6/0.4 的权重既能跟上真实变化，又不会让数字抖。
    private func sampleSpeed(progress p: Double, total: Int64) {
        guard p >= 0, total > 0 else { return }
        let done = p * Double(total)
        let now = Date()

        guard let last = lastTickAt else {
            lastTickAt = now
            lastTickBytes = done
            return
        }

        let dt = now.timeIntervalSince(last)
        // 回调太密就先不更新：0.4 秒以下的间隔算出来的速度没有意义。
        guard dt >= 0.4 else { return }

        let instant = max(0, (done - lastTickBytes) / dt)
        speedBytesPerSec = speedBytesPerSec > 0
            ? speedBytesPerSec * 0.6 + instant * 0.4
            : instant
        lastTickAt = now
        lastTickBytes = done
    }

    private func updateBadge(_ r: SelfUpdateResult) -> some View {
        let (text, bg): (String, Color) = {
            switch r {
            case .notConfigured:      return ("未配置", .gray)
            case .upToDate:           return ("最新", .green)
            case .updateAvailable:    return ("有新版", .blue)
            case .failed:             return ("失败", .red)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(bg, in: Capsule())
    }

    private func color(for r: SelfUpdateResult) -> Color {
        switch r {
        case .notConfigured:    return .orange
        case .upToDate:         return .green
        case .updateAvailable:  return .blue
        case .failed:           return .red
        }
    }

    // MARK: - 动作

    /// 一次点击走完整条：测速 → 判断 → 有新版就下载。
    ///
    /// 不做二次确认。用户的原话是「点一下就自动判断、自动下载」，
    /// 中间插一个「要下载吗」的弹窗就是把他的要求又推回去一次。
    ///
    /// 测速只做一次：`check()` 返回的 `win` 就是那条最快的线路，
    /// 下载直接复用它。再单独 race 一轮是白等。
    private func runCheckAndDownload() async {
        checking = true
        result = nil
        savedFile = nil
        progress = 0
        totalBytes = 0
        speedBytesPerSec = 0
        lastTickAt = nil
        lastTickBytes = 0
        lineNote = ""

        let outcome = await SelfUpdate.check()
        result = outcome.result
        checking = false

        // 只有「有新版」才继续。已是最新 / 失败都停在这里。
        guard case .updateAvailable = outcome.result, let win = outcome.win else { return }

        guard SelfUpdate.downloadURL(for: win) != nil else {
            result = .failed(reason: "这个版本里没有可安装的包")
            return
        }

        downloading = true
        progress = 0
        totalBytes = win.ipaSize

        do {
            // 进度回调是从 URLSession 的后台队列来的，@State 只能在主线程改，
            // 所以闭包里显式跳一次 MainActor。这不是多余的保险 ——
            // 直接写 progress = p 会触发「Publishing changes from
            // background threads is not allowed」并在真机上表现为界面卡住。
            let file = try await SelfUpdate.download(win: win) { p, total in
                Task { @MainActor in
                    // [R82] p == -3：这条线路卡死了，正在换下一条。
                    // 这**不是**失败 —— 进度归零继续留着进度条，另外给一句话
                    // 说明，否则用户看到 0% 会以为重头开始下、白等了。
                    //
                    // 原来的 -2 分支（判定卡死就直接报失败）已经删掉：
                    // 那时下载只走一条线路，卡住就没退路；现在会自动换线，
                    // 报「失败」等于把还能继续的过程说成结束了。
                    if p == -3 {
                        // 置 -1 而不是 0：0% 的空进度条正是「卡住了」的观感，
                        // 而这一刻是在换线路、还没开始收字节，用不确定态更诚实。
                        progress = -1
                        speedBytesPerSec = 0
                        lastTickAt = nil
                        lastTickBytes = 0
                        lineNote = "这条线路卡住了，换下一条继续"
                        return
                    }
                    // 真的开始有字节了，把那句提示收掉。
                    if p > 0 { lineNote = "" }
                    progress = p
                    if total > 0 { totalBytes = total }
                    // [R81] 速度采样。用 totalBytes 而不是闭包里的 total：
                    // 服务器偶尔只在响应头给一次 Content-Length，之后回调
                    // 里带的 total 可能是 0，那时候要用已经记下来的总量。
                    sampleSpeed(progress: p, total: total > 0 ? total : totalBytes)
                }
            }
            savedFile = file
            // [R60-下载锚点污染] 记「下过这个版本」，**不是**「已安装」。
            //
            // 原来是 `markInstalled`，紧跟在 `savedFile = file` 之后执行。
            // 可这个位置只是「文件落在本地」，用户还得在共享面板里走系统
            // 安装流程，那一步成败 App 拿不到回调。写成「已安装」的后果
            // 用户实测过：第一次下载失败 → 第二次下载成功、弹共享面板 →
            // 安装报 301 没装上 → 第三次检查时锚点已写好，界面显示
            // 「已是最新」，再也升不上去。
            SelfUpdate.markDownloaded(win)
            // [R44] 下完立刻弹共享面板。用户原话「下载完更新文件后要出来
            // 弹窗，弹窗里面有苹果共享的那个界面」—— 不是「在列表里多一行」。
            shareItem = ShareItem(url: file)
        } catch {
            // 失败不把 result 打回「有新版」—— 那会让人以为没下载成功是错觉。
            //
            // [R59] 看门狗取消任务时抛的是 CancellationError，它的
            // localizedDescription 是「已取消」这种没信息量的话。
            // 那种情况上面闭包已经写好了更清楚的说明，这里不要覆盖它。
            if error is CancellationError {
                // 保留闭包里已经设置的失败文案。
            } else if (error as? URLError)?.code == .cancelled {
                // 同上：被取消（看门狗或系统）不覆盖已有说明。
            } else {
                result = .failed(reason: (error as? SelfUpdateError)?.errorDescription
                                        ?? error.localizedDescription)
            }
        }

        downloading = false
    }
}

// MARK: - [R44] 共享面板

/// `.sheet(item:)` 需要 Identifiable。包一层是为了让「同一个文件再弹一次」
/// 也算新 item —— 直接拿 URL 当 id 的话，用户在列表里再点一次
/// 「分享 / 安装」不会弹（id 没变，SwiftUI 认为还是同一个 sheet）。
///
/// ⚠️ `id` 必须是一个**存下来的**常量，不能写成 `Date().timeIntervalSince1970`
/// 那种计算属性：SwiftUI 每次重算 body 都会读一次 id，每次都不同的话
/// 它会认为 item 一直在变，反复 dismiss / present 同一张 sheet。
private struct ShareItem: Identifiable {
    let url: URL
    let id: String

    init(url: URL) {
        self.url = url
        self.id = url.path + "#" + UUID().uuidString
    }
}

/// 就是系统那套共享面板，什么都不筛。
///
/// 为什么不复用 `MinisShareSheet`：见文件头的说明 —— 它会在扩展名
/// 解析不出 UTI 时把文件**复制成 .bin**。`.ipa` 正好落在那条分支上，
/// 复制完 TrollStore / 全能签都认不出来。这里直接用原文件。
private struct IPAShareSheet: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url],
                                          applicationActivities: nil)
        // iPad 上不设 popover 锚点会直接崩（NSInvalidArgumentException）。
        // 本 App 主目标只有 iPhone，但设置页在 iPad 分栏下也可能被点到，
        // 所以两句都要有。sourceView 用一个零尺寸视图即可。
        if let pop = vc.popoverPresentationController {
            let anchor = UIView(frame: .zero)
            pop.sourceView = anchor
            pop.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

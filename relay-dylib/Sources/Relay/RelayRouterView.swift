//
//  RelayRouterView.swift
//  Minis — 路由器管理页
//
//  ============================================================
//  结构照模板 ui.html 的 buildRouter()（2026-11-10 R43 重写）
//
//    ① route-card   线路卡：图标圆 + 「路由器 · 直连/在外」+ 在线 badge
//                   下面三行：路由器地址 / 指令通道 / 型号
//    ② stats        三列：运行时长 / 可用内存 / 系统负载
//    ③ tip warn     内存/交换告警（只在真有问题时出现）
//    ④ grp-head + card   「重启中转站后台」一行
//    ⑤ grp-head + card   「重启路由器后台」一行（红色）
//
//  上一版把两个重启按钮做成了「日常维护 / 危险操作」两组带标题的
//  大按钮，还夹了一条红色警示条。结构比模板重，而且「危险」两个字
//  挂在分组标题上，反而看不出到底哪个按钮危险 —— 模板的做法更直接：
//  危险只体现在**那一行文字变红**，别的都不用喊。
//
//  ============================================================
//  几处不能动的判断（都有代价，别再简化）：
//
//  · `canPerform` 不看 device / routerOnline。那两个是上一次刷新的快照，
//    在外时 airboot 本来就探不到，拿它当前置条件会把按钮变灰，用户会
//    以为「在外就不能重启」—— 实际两条线路都能重启。
//
//  · 「型号」是用户自己填的（RelayVault.routerModel），不是探测出来的。
//    MT7621 这类型号在 airboot 的响应里没有，硬编一个等于骗人。
//    留空就显示「未配置」，去设置页填一次。
//  ============================================================

import SwiftUI

struct RelayRouterView: View {

    @ObservedObject private var store = RelayStore.shared
    @State private var pending: RelayStore.PowerAction?
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if store.unconfigured {
                    setupCard
                    // 结果条不能只在「已配置」分支里显示。
                    // 没配密码时点重启，perform 会把「需要先填密码」写进
                    // actionResult；这里不渲染，用户点完按钮屏幕一动不动。
                    if let r = store.actionResult {
                        resultBanner(r)
                    }
                    // errorText 同理：没配密钥时 refresh 也可能写出
                    // 「路由器没响应」这类话，不渲染等于白算。
                    if !store.errorText.isEmpty {
                        errorCard
                    }
                } else {
                    routeCard

                    statsCard

                    if let hint = rebootHint {
                        hint
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if !store.errorText.isEmpty {
                        errorCard
                    }

                    groupTitle("重启中转站后台")
                    actionCard(action: .restartRelay,
                               icon: "arrow.clockwise",
                               tint: .blue,
                               title: "重启中转站后台",
                               note: "网页断几秒，无线网络不断",
                               danger: false)

                    groupTitle("重启路由器后台")
                    actionCard(action: .rebootRouter,
                               icon: "power",
                               tint: .red,
                               title: "重启路由器后台",
                               note: rebootNote,
                               danger: true)

                    if let r = store.actionResult {
                        resultBanner(r)
                    }
                }

                settingsLink
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("路由器")
        .navigationBarTitleDisplayMode(.inline)
        // [R42-统一外观] 和设置首页同一套底色 / 紧致标题。
        .settingsPageChrome()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.busy {
                    ProgressView().scaleEffect(0.8)
                }
            }
        }
        .refreshable {
            await store.refresh()
        }
        .onAppear {
            store.refreshIfStale()
            RelayStore.shared.clearActionResult()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            store.refreshIfStale()
        }
        .confirmationDialog(
            pending?.confirmTitle ?? "",
            isPresented: Binding(get: { pending != nil },
                                 set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let action = pending {
                Button(action.confirmButton, role: .destructive) {
                    let a = action
                    pending = nil
                    Task { await store.perform(a) }
                }
                Button("取消", role: .cancel) { pending = nil }
            }
        } message: {
            Text(pending?.confirmMessage ?? "")
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                RelaySettingsView()
            }
        }
    }

    // MARK: - ① 线路卡

    /// 还没配过任何密钥时的引导。
    ///
    /// 判据是 `store.unconfigured`（后台密码与路由密钥**都**没有），
    /// 不能只看后台密码：重启路由器走 airboot，只需要路由指令密钥，
    /// 填过密钥的人不该被要求再填一遍密码。
    ///
    /// [R33-直填] 直接给表单，不是「去设置」按钮。用户在路由器页就该能
    /// 一次填完地址和密码，不用再跳到设置页找一遍 —— 那个动作他早就
    /// 明确要求取消过。
    private var setupCard: some View {
        RelayQuickSetupForm {
            await store.refresh()
        }
    }

    /// 对齐模板 `.route-card`：主行（圆图标 42 + 标题 17 + 副标题 13 + badge）
    /// 加三行 `.route-line`（行高 11、字号 15、左 16 右 0 的半像素分隔线）。
    private var routeCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(routeTint.opacity(0.13))
                        .frame(width: 42, height: 42)
                    Image(systemName: store.route?.icon ?? "questionmark")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(routeTint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.route?.routerLabel ?? "正在判定…")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(store.route?.routerDisplayAddress ?? "线路还没判出来")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                onlineBadge
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)

            routeLine("路由器地址", store.route?.routerDisplayAddress ?? "未配置", mono: true)
            routeLine("指令通道", channelText, ok: channelReady)
            routeLine("型号", modelText, mono: false)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var onlineBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(onlineTint)
                .frame(width: 5, height: 5)
            Text(onlineShortText)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .background(onlineTint.opacity(0.13))
        .foregroundColor(onlineTint)
        .clipShape(Capsule())
        .fixedSize()
    }

    private var routeTint: Color {
        guard let r = store.route else { return .secondary }
        return r.isLan ? Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255)
                       : Color(red: 0x00/255, green: 0x7A/255, blue: 0xFF/255)
    }

    private var onlineTint: Color {
        switch store.routerOnline {
        case .some(true):  return Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255)
        case .some(false): return Color(red: 0xFF/255, green: 0x3B/255, blue: 0x30/255)
        case .none:        return Color.secondary.opacity(0.6)
        }
    }

    private var onlineShortText: String {
        switch store.routerOnline {
        case .some(true):  return "在线"
        case .some(false): return "没响应"
        case .none:        return "检测中"
        }
    }

    /// 指令通道能不能用 —— 只看**有没有密钥**，不看上次请求的结果。
    /// 上次失败可能是网络抖动，拿它显示「不可用」会让用户以为密钥坏了。
    private var channelReady: Bool {
        _ = store.vaultRevision
        return !RelayVault.shared.effectiveRouterKey.isEmpty
    }

    private var channelText: String {
        if store.route == nil { return "等待线路" }
        return channelReady ? "就绪" : "还没填密钥"
    }

    private var modelText: String {
        _ = store.vaultRevision
        let m = RelayVault.shared.routerModel
        return m.isEmpty ? "未配置" : m
    }

    private func routeLine(_ k: String, _ v: String, mono: Bool = false,
                           ok: Bool? = nil) -> some View {
        HStack(spacing: 8) {
            Text(k)
                .font(.system(size: 15))
                .foregroundColor(.primary)
            Spacer(minLength: 8)
            Text(v)
                .font(.system(size: mono ? 13 : 15,
                              design: mono ? .monospaced : .default))
                .foregroundColor(ok == true
                                 ? Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255)
                                 : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        // 分隔线从左边 16 开始，不到右边 —— 与模板 .route-line::before 一致
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
                .padding(.leading, 16)
        }
    }

    // MARK: - ② 三列指标

    private var statsCard: some View {
        HStack(spacing: 0) {
            metric(title: "运行时长",
                   value: store.device?.uptimeText ?? "—",
                   icon: "clock",
                   warn: false)
            statDivider
            metric(title: "可用内存",
                   value: store.device?.memAvailText ?? "—",
                   icon: "memorychip",
                   warn: store.device?.memLow == true)
            statDivider
            metric(title: "系统负载",
                   value: store.device?.loadText ?? "—",
                   icon: "speedometer",
                   warn: store.device?.loadHigh == true)
        }
        .padding(.vertical, 16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 模板 `.stat + .stat::before`：左边缘一条 0.5 竖线，上下各留 2。
    private var statDivider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 0.5)
            .padding(.vertical, 2)
    }

    private func metric(title: String, value: String, icon: String, warn: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.primary.opacity(0.32))
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundColor(warn ? .orange : .primary)
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - ③ 健康提示

    /// 只在真的有问题时出现（后端 should_reboot / 本地阈值）。
    /// 没症状就整块不渲染 —— 模板里这块本来就不是常驻的。
    private var rebootHint: AnyView? {
        guard let d = store.device, d.recommendReboot,
              let reason = d.rebootReason else { return nil }

        // 把「中转站自己占多少」也带出来：这一项最能说明「重启中转站
        // 就能回收」是不是真的，比单说一句内存低有用。
        var body = reason
        if d.relayRssKB > 0 {
            body += "。中转站自身占用 \(d.relayRssText)"
        }
        body += "。重启中转站可回收，无线网络不会断。"

        return AnyView(
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(Color(red: 0xFF/255, green: 0x95/255, blue: 0x00/255))
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.memLow ? "内存偏低，建议重启" : "该重启了")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(red: 0xC8/255, green: 0x6A/255, blue: 0x00/255))
                    Text(body)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(Color(red: 0xFF/255, green: 0x95/255, blue: 0x00/255).opacity(0.11))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
    }

    // MARK: - ④⑤ 分组标题 + 操作行

    /// 模板 `.grp-head`：13pt semibold、主色，不是灰色的 caption。
    /// 上一版用的是灰色 caption，读起来像注释而不像分组名。
    private func groupTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.leading, 2)
    }

    /// 模板 `.act`：一行，左圆图标 30、中间两行（16.5 标题 / 12.5 说明）、右箭头。
    /// 危险项只把标题染红，不加红框、不加警示条 —— 那是上一版的做法，
    /// 反而让「哪个按钮危险」不直观。
    private func actionCard(action: RelayStore.PowerAction,
                            icon: String,
                            tint: Color,
                            title: String,
                            note: String,
                            danger: Bool) -> some View {
        let enabled = store.canPerform(action)
        return Button {
            pending = action
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16.5))
                        .foregroundColor(danger
                                         ? Color(red: 0xFF/255, green: 0x3B/255, blue: 0x30/255)
                                         : .primary)
                    Text(note)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// 重启路由器那行的小字。
    ///
    /// 说实话，不粉饰：
    ///   · 判断不出线路 → 直说「还没判出来」，不要拿它假装是禁用原因
    ///   · 在家        → 走 airboot（http 80），最快
    ///   · 在外        → 也走 airboot（https 443，隧道转进去），
    ///                    **只需要路由器指令密钥**，不需要后台密码
    ///                   （2026-11-09 实测：直接回 {"ok":true,"svc":"airboot"}）
    ///   · 一个密钥都没有 → 提示去填，因为这时候点了也只会报错
    private var rebootNote: String {
        _ = store.vaultRevision   // 建依赖，见 RelayStore.vaultRevision 的说明
        guard store.route != nil else { return "线路还没判出来，稍等一下" }
        if store.route?.isLan == true { return "整台重启，断网约 1 分钟" }
        if RelayVault.shared.effectiveRouterKey.isEmpty { return "还缺密钥，先去设置里填一次" }
        return "经隧道下发 airboot，只需指令密钥"
    }

    // MARK: - 结果 / 错误 / 设置入口

    private func resultBanner(_ r: (ok: Bool, text: String)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(r.ok ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.ok ? "已完成" : "没能完成")
                    .font(.system(size: 14, weight: .semibold))
                Text(r.text)
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background((r.ok ? Color.green : Color.red).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var errorCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 15))
                .foregroundColor(.orange)
            Text(store.errorText)
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(Color.orange.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var settingsLink: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                Text("地址、密钥与型号设置")
                    .font(.system(size: 12.5))
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }
}

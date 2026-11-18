//
//  RelayRootView.swift
//  RelayDylib — 首页 + 自检页
//
//  首页三样东西，分两组（照官方设置页截图的分组结构）：
//    · AI 服务商：添加 AI 中转站
//    · 设备管理：中转站后台、路由器后台
//  自检页的入口按用户要求已移除（view 代码保留，里面有 v4 的代理状态显示）。
//  前两个是从 fork 的 Relay/ 目录原样搬过来的页面，零改动 —— 它们只依赖
//  RelayStore / RelayVault / RelayRoute，不碰 App 内部的模型层。
//
//  「添加中转站」是 v3：它不碰 App 的内部类型，只通过「运行时可查的
//  @objc 配置通道」让 App 自己去写自己（见 RelayBridge.m）。
//
//  自检页是给这套注入方案留的听诊器：以后官方换版本、换 Info.plist，
//  打开它就能确认「dylib 加载了没有 / ATS 放没放行 / 本地网络给没给权限」，
//  不用猜、也不用接调试器。
//

import SwiftUI
import UIKit

// MARK: - 首页

struct RelayHomeView: View {

    var body: some View {
        NavigationStack {
            List {
                // 组一：AI 服务商 —— 「添加 AI 中转站」跟在（官方原生）「添加 AI
                // 服务商」下面，用同一套蓝色圆角方块图标。这里只放我们注入的那一项。
                Section {
                    NavigationLink {
                        RelayAddProviderView()
                    } label: {
                        RelaySettingsRow(symbol: "network",
                                         tint: RelaySettingsDesign.blue,
                                         title: "添加 AI 中转站",
                                         subtitle: "写进 App 的服务商与模型列表")
                    }
                } header: {
                    sectionHeader("AI 服务商")
                }

                // 组二：设备管理 —— 中转站后台、路由器后台单独成一类目。
                Section {
                    NavigationLink {
                        RelayAdminView()
                    } label: {
                        // 配色/放大系数照 fork 设置页同一行：server.rack 天生偏小，1.25。
                        RelaySettingsRow(symbol: "server.rack",
                                         tint: RelaySettingsDesign.blue,
                                         title: "中转站后台",
                                         subtitle: "查看状态、改密码、重启",
                                         glyphScale: 1.25)
                    }

                    NavigationLink {
                        RelayRouterView()
                    } label: {
                        RelaySettingsRow(symbol: "wifi.router.fill",
                                         tint: RelaySettingsDesign.green,
                                         title: "路由器后台",
                                         subtitle: "线路判定与 airboot 操作",
                                         glyphScale: 1.1)
                    }
                } header: {
                    sectionHeader("设备管理")
                }

            }
            // 卡片式列表：压掉系统分组底色，透出统一背景；分组标题 13pt/600。
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .listStyle(.insetGrouped)
            .navigationTitle("中转站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { RelayBallInstaller.shared.closeHome() }
                }
            }
        }
    }

    /// 分组标题：照 fork 设计稿 13pt/600、primary 色、左缩 34、不大写。
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(RelaySettingsDesign.sectionHeaderFont)
            .foregroundStyle(Color(.label))
            .textCase(nil)
            .padding(.leading, RelaySettingsDesign.sectionHeaderLeading - 16)
    }
}

// MARK: - 自检页

struct RelaySelfCheckView: View {

    @ObservedObject private var store = RelayStore.shared

    @State private var testURL = "http://192.168.1.88/"
    @State private var testing = false
    @State private var resultText: String?
    @State private var resultOK: Bool?

    var body: some View {
        List {
            routeSection
            proxySection
            environmentSection
            atsSection
            networkSection
        }
        .navigationTitle("自检")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 线路判定

    /// 判定结果的「为什么」都摆在这里。
    /// 用户 2026-11-18 要求判定要准、要能看出现在用的是 WiFi 还是数据，
    /// 这一块就是给他核对的地方 —— 判得对不对，一眼能查。
    private var routeSection: some View {
        Section {
            row("当前网络", value: store.route?.network.label ?? "判定中")
            row("线路", value: store.route?.stateText ?? "判定中")
            row("依据", value: store.route?.probeText ?? "—")
        } header: {
            Text("线路判定")
        } footer: {
            Text("在系统里换网（WiFi ↔ 数据）会自动重判，回前台也会重判一次。这里显示最近一次结果。")
                .font(.footnote)
        }
    }

    // MARK: 本地代理（无感换线）

    /// 直接显示代理的监听状态与当前转发目标。
    /// 换网后回来这一节会跟着刷新（route 变化时整页重绘），
    /// 「当前转发目标」从内网跳到域名就说明换线生效了。
    private var proxySection: some View {
        Section {
            row("本地监听", value: RelayProxy.shared.isRunning
                ? "127.0.0.1:\(RelayProxyConfig.port)（正常）"
                : "未启动" + (RelayProxy.shared.lastError.isEmpty ? "" : "：\(RelayProxy.shared.lastError)"))
            row("当前转发目标", value: RelayProxy.shared.targetBase.isEmpty ? "—" : RelayProxy.shared.targetBase, mono: true)
            row("已转发请求", value: "\(RelayProxy.shared.requestCount)")
        } header: {
            Text("自动换线代理")
        } footer: {
            Text("聊天服务商地址填 http://127.0.0.1:18923 后，请求全部经过这里。换网后「当前转发目标」会跟着变，聊天不用手动切模型。")
                .font(.footnote)
        }
    }

    // MARK: 环境

    private var environmentSection: some View {
        Section("环境") {
            row("App", value: appVersion)
            row("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
            row("dylib", value: dylibPath, mono: true)
        }
    }

    private var atsSection: some View {
        Section {
            row("NSAllowsArbitraryLoads", value: atsArbitraryLoads ? "是" : "否")
            row("本地网络权限说明", value: localNetworkDescription ? "有" : "缺")
        } header: {
            Text("Info.plist")
        } footer: {
            Text("官方包来自上游基线，这两项本来就带。显示「否 / 缺」说明手上这个不是官方那版包，http 内网请求会被系统拦掉。")
                .font(.footnote)
        }
    }

    // MARK: 网络

    private var networkSection: some View {
        Section {
            TextField("地址", text: $testURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(.body, design: .monospaced))

            Button {
                Task { await runTest() }
            } label: {
                HStack {
                    Text(testing ? "测试中…" : "发起请求")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing)

            if let resultText {
                Text(resultText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(resultOK == true ? Color.green : Color.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("内网连通性")
        } footer: {
            Text("用 http 明文地址测，才能看出 ATS 是否放行。报错里 -1022 = 被 ATS 拦，-1009 / -1004 = 连不上或权限被拒。")
                .font(.footnote)
        }
    }

    // MARK: 组件

    private func row(_ title: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    // MARK: 数据

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var dylibPath: String {
        Bundle(for: RelayBallInstaller.self).bundlePath
    }

    private var atsArbitraryLoads: Bool {
        let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        return ats?["NSAllowsArbitraryLoads"] as? Bool ?? false
    }

    private var localNetworkDescription: Bool {
        let text = Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        return !(text ?? "").isEmpty
    }

    // MARK: 请求

    /// 整个函数在主线程上跑，只有 `await session.data` 那一下会让出。
    /// 这样状态改动能直接写，不用绕 MainActor.run 去捕获 self。
    @MainActor
    private func runTest() async {
        testing = true
        resultText = nil
        resultOK = nil
        defer { testing = false }

        guard let url = URL(string: testURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            resultOK = false
            resultText = "地址不合法"
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            resultOK = true
            resultText = "HTTP \(code) · \(data.count) 字节"
        } catch {
            let ns = error as NSError
            resultOK = false
            resultText = "\(ns.domain) \(ns.code)\n\(ns.localizedDescription)"
        }
        session.invalidateAndCancel()
    }
}

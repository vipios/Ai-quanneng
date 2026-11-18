//
//  RelayRootView.swift
//  RelayDylib — 首页 + 自检页
//
//  首页只有三样东西：中转站后台、路由器后台、自检。
//  前两个是从 fork 的 Relay/ 目录原样搬过来的页面，零改动 —— 它们只依赖
//  RelayStore / RelayVault / RelayRoute，不碰 App 内部的模型层。
//
//  自检页是给这套注入方案留的听诊器：以后官方换版本、换 Info.plist，
//  打开它就能确认「dylib 加载了没有 / ATS 放没放行 / 本地网络给没给权限」，
//  不用猜、也不用接调试器。
//

import SwiftUI
import UIKit

// MARK: - 首页

struct RelayHomeView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        RelayAdminView()
                    } label: {
                        row("server.rack", "中转站后台", "查看状态、改密码、重启")
                    }

                    NavigationLink {
                        RelayRouterView()
                    } label: {
                        row("wifi.router.fill", "路由器后台", "线路判定与 airboot 操作")
                    }
                } header: {
                    Text("设备")
                }

                Section {
                    NavigationLink {
                        RelaySelfCheckView()
                    } label: {
                        row("stethoscope", "自检", "注入状态 / ATS / 内网连通性")
                    }
                }
            }
            .navigationTitle("中转站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 自检页

struct RelaySelfCheckView: View {

    @State private var testURL = "http://192.168.1.88/"
    @State private var testing = false
    @State private var resultText: String?
    @State private var resultOK: Bool?

    var body: some View {
        List {
            environmentSection
            atsSection
            networkSection
        }
        .navigationTitle("自检")
        .navigationBarTitleDisplayMode(.inline)
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

//
//  RelayRootView.swift
//  RelayDylib — v1 自检页
//
//  这一版故意不搬任何业务页面，只做一件事：证明「注入链路 + 网络通路」
//  这一段是通的。三个要验证的点都摆在界面上，真机上一眼就能看出来：
//
//    1. dylib 到底有没有被加载（能打开这个面板 = 加载了）
//    2. Info.plist 的 ATS 有没有放行 http（测 http://192.168.x.x）
//    3. 本地网络权限弹没弹、给没给（同一个请求失败时会区分报错码）
//
//  第 2、3 点是当初在 fork 里踩过的坑：fork 版是自己编的 Info.plist，
//  这两项当初就是后补进去的；注入官方包时它们不一定在，所以必须能自测。
//

import SwiftUI
import UIKit

struct RelayRootView: View {

    @State private var testURL = "http://192.168.1.88/"
    @State private var testing = false
    @State private var resultText: String?
    @State private var resultOK: Bool?

    var body: some View {
        List {
            environmentSection
            atsSection
            networkSection
            pendingSection
        }
        .navigationTitle("中转站 · 自检")
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
            Text("这两项由注入脚本补写。显示「否 / 缺」说明补写没生效，http 内网请求会被系统拦掉。")
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

    // MARK: 待接入

    private var pendingSection: some View {
        Section {
            pendingRow("server.rack", "中转站后台")
            pendingRow("wifi.router.fill", "路由器后台")
            pendingRow("plus.circle", "添加 AI 中转站")
        } header: {
            Text("功能")
        } footer: {
            Text("v1 只验证注入链路，这三项在 v2 / v3 接入。")
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

    private func pendingRow(_ symbol: String, _ title: String) -> some View {
        HStack {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text("v2")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
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

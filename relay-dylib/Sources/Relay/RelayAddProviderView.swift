//
//  RelayAddProviderView.swift
//  RelayDylib — 「添加中转站」表单
//
//  这一页只负责收四个值：显示名、类型、地址、Key。
//  交了之后不在这里写入 —— 见 RelayProviderInstaller.submit 的注释：
//  必须先把本页关掉，App 自己的确认弹窗才露得出来。
//
//  地址默认填本地代理（127.0.0.1:18923）：这样配出来的服务商走的是
//  「无感自动换线」—— App 请求固定发到本地代理，代理按当前线路转发到
//  内网或外网。用户不用再手动切内外网模型（见 RelayProxy.swift 顶部）。
//

import SwiftUI

struct RelayAddProviderView: View {

    /// ProviderType.rawValue。中转站基本都是 OpenAI 兼容，默认第一项。
    private static let types: [(raw: String, title: String)] = [
        ("openAI", "OpenAI 兼容"),
        ("anthropic", "Anthropic 兼容"),
        ("openRouter", "OpenRouter"),
    ]

    @State private var label = "中转站"
    @State private var typeIndex = 0
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var appendV1 = true
    @State private var submitted = false

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 地址填了就必须是 http(s)，不然 App 那边会拿它当相对路径拼，报错还很难懂。
    private var baseURLProblem: String? {
        guard !trimmedBaseURL.isEmpty else { return nil }
        guard let url = URL(string: trimmedBaseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return "地址要以 http:// 或 https:// 开头"
        }
        return nil
    }

    private var canSubmit: Bool {
        !submitted && !trimmedLabel.isEmpty && baseURLProblem == nil
    }

    var body: some View {
        Form {
            Section {
                TextField("显示名", text: $label)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker("类型", selection: $typeIndex) {
                    ForEach(Self.types.indices, id: \.self) { index in
                        Text(Self.types[index].title).tag(index)
                    }
                }
            } header: {
                Text("服务商")
            } footer: {
                Text("显示名在 App 里要唯一，重名会被拒。类型选「OpenAI 兼容」一般就够了。")
                    .font(.footnote)
            }

            Section {
                TextField(RelayProxyConfig.localBaseURL, text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(.body, design: .monospaced))

                Toggle("自动追加 /v1", isOn: $appendV1)
            } header: {
                Text("地址")
            } footer: {
                if let problem = baseURLProblem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                } else {
                    Text("默认就是本地自动换线地址，别改。这样 WiFi 切蜂窝、在家出门都会自动走对线路，不用手动切模型。")
                        .font(.footnote)
                }
            }

            Section {
                SecureField("sk-…", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("API Key")
            } footer: {
                Text("Key 只会进 App 的钥匙串，不会留在这一页。留空也能先建，之后再在 App 设置里补。")
                    .font(.footnote)
            }

            Section {
                Button {
                    submit()
                } label: {
                    HStack {
                        Text("保存")
                        Spacer()
                        if submitted { ProgressView() }
                    }
                }
                .disabled(!canSubmit)
            } footer: {
                Text("点保存后这一页会关掉，接着 App 会弹一次它自己的确认弹窗 —— 那是官方给外部改配置设的闸门，点「允许」才会真正写进去。写完 App 会自己去拉模型列表。")
                    .font(.footnote)
            }
        }
        .navigationTitle("添加中转站")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: prefillIfNeeded)
    }

    // MARK: - 行为

    /// 地址默认填本地代理 —— 走它才有无感自动换线。
    /// 用户改过就别覆盖（留着手动填固定地址的自由）。
    private func prefillIfNeeded() {
        guard baseURL.isEmpty else { return }
        baseURL = RelayProxyConfig.localBaseURL
    }

    private func submit() {
        guard canSubmit else { return }
        submitted = true
        RelayProviderInstaller.submit(
            label: trimmedLabel,
            providerType: Self.types[typeIndex].raw,
            baseURL: trimmedBaseURL,
            apiKey: apiKey,
            appendV1: appendV1
        )
    }
}

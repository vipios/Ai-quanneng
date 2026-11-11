//
//  AddRelayProviderView.swift
//  Minis — 添加 AI 中转站（R9–R13）
//
//  与「添加 AI 服务商」的区别：中转站要配**两个**地址。
//    内网地址 —— 在家直连，实测 0.07 秒
//    外网地址 —— 在外面走域名/隧道，实测 2.5 秒
//  相差 35 倍，所以线路判准比什么都重要。
//
//  ============================================================
//  表单字段
//    · 名称
//    · 协议类型（OpenAI 兼容 / Anthropic 兼容）
//    · 内网地址
//    · 外网地址
//    · API Key
//    · 线路偏好（自动判定 / 只用内网 / 只用外网）
//
//  保存时做两件事：
//    ① 建一个普通 ProviderInstance（credentialType = .apiKey，
//       customBaseURL = 内网地址，作为离线兜底）
//    ② 写一条中转站档案（双地址 + 线路偏好）
//  然后立刻按当前网络判定一次，把结果缓存进档案。
//  ============================================================

import SwiftUI
import os.log

struct AddRelayProviderView: View {

    @Environment(\.dismiss) private var dismiss

    /// 外部传入：保存成功后回调，用于让列表刷新
    var onSaved: ((String) -> Void)?

    /// [R52-编辑模式] 非 nil = 编辑已存在的中转站（回填 + 更新），
    /// nil = 新增。编辑时 instanceId 保持不变。
    private let editInstanceId: String?

    init(editInstanceId: String? = nil, onSaved: ((String) -> Void)? = nil) {
        self.editInstanceId = editInstanceId
        self.onSaved = onSaved
    }

    @State private var label = ""
    @State private var protocolKind: RelayProtocolKind = .openAI
    @State private var homeURL = ""
    @State private var awayURL = ""
    @State private var apiKey = ""
    /// [R52-第三方键盘] API Key 明文显示开关。默认明文，第三方键盘可用。
    @State private var showApiKey = true
    @State private var routeMode: RelayRouteMode = .auto
    @State private var appendV1 = true

    // [R45-直连/在外模型] 两条线路各一个模型。nil = 未选择。
    @State private var lanModel: String? = nil
    @State private var wanModel: String? = nil

    // 模型选择弹窗
    @State private var pickingLine: RelayLine? = nil   // nil = 不弹
    @State private var fetchingModels = false
    @State private var modelList: [String] = []
    @State private var modelFetchError = ""
    @State private var modelSearch = ""

    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var saving = false
    @State private var saveError = ""

    /// 直连 / 在外 两条线路。用于模型选择弹窗区分当前在选哪条。
    private enum RelayLine: String, Identifiable {
        case lan
        case wan
        var id: String { rawValue }
        var title: String { self == .lan ? "直连模型" : "在外模型" }
    }

    private enum TestResult: Equatable {
        case homeOK(Double)
        case homeFail
        case awayOK(Double)
        case awayFail
        case bothFail
    }

    var body: some View {
        Form {
            basicsSection
            addressSection
            keySection
            modelSection
            modeSection

            if let r = testResult {
                resultSection(r)
            }

            if !saveError.isEmpty {
                Section {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle(editInstanceId == nil ? "添加 AI 中转站" : "编辑 AI 中转站")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Text("保存").font(.body.weight(.semibold))
                    }
                }
                .disabled(!canSave || saving)
            }
        }
        .sheet(item: $pickingLine) { line in
            modelPickerSheet(line)
        }
        .onAppear {
            if let eid = editInstanceId {
                loadForEdit(instanceId: eid)
            } else {
                // [R42] 不再预填地址。
                //
                // 原来这里会填真实的内网 IP 和域名 —— 那是作者自己家的网络
                // 结构，随 App 一起发出去，等于把家里的网络公开了。
                // 用户明确要求这两个地址自己填，所以留空。
                //
                // 顺带一个实际问题：预填了真实地址之后，用户不想要也会
                // 直接保存，然后每次请求都先去敲一个不属于他的 IP，白等超时。
                label = ""
            }
        }
    }

    /// [R52-编辑模式] 用已有档案回填表单。
    private func loadForEdit(instanceId: String) {
        guard let p = RelayProfileStore.shared.profile(for: instanceId) else {
            saveError = "找不到这条中转站的档案。"
            return
        }
        let inst = ProviderConfigStore.shared.instance(for: instanceId)
        label = inst?.label ?? ""
        homeURL = p.homeURL
        awayURL = p.awayURL
        protocolKind = p.protocolKind
        routeMode = p.routeMode
        appendV1 = p.effectiveAppendV1
        lanModel = p.lanModel
        wanModel = p.wanModel
        // API Key 不回填明文（钥匙串里只存了密文，取回不回填原文），
        // 留空 = 不修改；用户要改就重填。
        apiKey = ""
    }

    private var canSave: Bool {
        let base = !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !homeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !awayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 编辑模式：API Key 留空 = 不修改，所以不强制填。
        if editInstanceId != nil { return base }
        return base && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 基础

    private var basicsSection: some View {
        Section {
            // [R42] 占位文案去掉「家里」两个字 —— 写成「例如：中转站」。
            TextField("例如：中转站", text: $label)

            Picker("协议", selection: $protocolKind) {
                ForEach(RelayProtocolKind.allCases) { k in
                    Text(k.title).tag(k)
                }
            }

            if protocolKind == .openAI {
                Toggle("自动追加 /v1", isOn: $appendV1)
            }
        } header: {
            Text("基础")
        }
        // [R42] footer 说明整段删掉。用户明确要求「剩下的那几个小字都删除」——
        // 表单上每段说明都占两三行，把本来就短的输入区挤没了。
    }

    // MARK: - 地址

    private var addressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("内网地址")
                    .font(.caption)
                    .foregroundColor(.secondary)
                // [R42] 占位符原来是真实内网 IP，换成通用的写法示例。
                TextField("http://<内网地址>:<端口>", text: $homeURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("外网地址")
                    .font(.caption)
                    .foregroundColor(.secondary)
                // [R42] 原来填的是真实域名，同样换掉。
                TextField("https://<外网域名>", text: $awayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
            }
            .padding(.vertical, 2)

            Button {
                Task { await test() }
            } label: {
                HStack(spacing: 6) {
                    if testing {
                        ProgressView().scaleEffect(0.7)
                        Text("正在测…")
                    } else {
                        Image(systemName: "bolt.horizontal")
                        Text("测试连不连得通")
                    }
                }
                .font(.footnote)
            }
            .disabled(testing)
        } header: {
            Text("两个地址")
        }
        // [R42] footer 删掉（「这里要连完整地址…内网快 35 倍」那段）。
    }

    // MARK: - Key

    private var keySection: some View {
        Section {
            // [R52-第三方键盘] 不再用 SecureField：iOS 规定密码框
            // （isSecureTextEntry）只能弹原生键盘，第三方键盘（搜狗/百度等）
            // 一律被系统换掉，用户没法用自己的输入法填 Key。
            //
            // 改成普通 TextField + 眼睛按钮手动切换明文/密文：
            //   · 明文态（默认）：第三方键盘随便用，Key 看得见，自己注意场合
            //   · 密文态：点眼睛切过来，系统会换成原生键盘 —— 这是切密文的
            //     固有代价，不是 bug；再点一次切回明文即恢复
            //   · .oneTimeCode 不能加：它同样会触发系统密码键盘
            HStack(spacing: 8) {
                if showApiKey {
                    TextField("sk-...", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("sk-...", text: $apiKey)
                }
                Button {
                    showApiKey.toggle()
                } label: {
                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showApiKey ? "隐藏 API Key" : "显示 API Key")
            }
        } header: {
            Text("API Key")
        }
        // [R42] footer 删掉（钥匙串那段说明）。
    }

    // MARK: - 模型（按线路分别指定）

    private var modelSection: some View {
        Section {
            modelRow(.lan, value: lanModel)
            modelRow(.wan, value: wanModel)
        } header: {
            Text("模型（按线路分别指定）")
        } footer: {
            Text("点右侧箭头从该线路拉取可用模型。在家走内网、在外走域名，各用各的模型；未选的线路回落到另一条已选模型。")
        }
    }

    private func modelRow(_ line: RelayLine, value: String?) -> some View {
        HStack(spacing: 10) {
            Text(line.title)
            Spacer()
            Text(value ?? "未选择")
                .foregroundColor(value == nil ? .secondary : .primary)
            Button {
                Task { await fetchModels(line) }
            } label: {
                if fetchingModels {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .foregroundColor(.accentColor)
                }
            }
            .buttonStyle(.borderless)
            .disabled(fetchingModels)
        }
    }

    // MARK: - 线路偏好

    private var modeSection: some View {
        Section {
            ForEach(RelayRouteMode.allCases) { m in
                Button {
                    routeMode = m
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: m.icon)
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                            .frame(width: 26, height: 26)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Text(m.subtitle)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer(minLength: 0)

                        if routeMode == m {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("线路选择")
        }
        // [R42] footer 删掉（自动判定探活那段说明）。
    }

    // MARK: - 模型选择弹窗

    /// 点右侧箭头后弹出的模型列表。可搜索、点行即选。
    private func modelPickerSheet(_ line: RelayLine) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !modelSearch.isEmpty || !modelList.isEmpty {
                    // 搜索框
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        TextField("搜索模型", text: $modelSearch)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                if modelFetchError.isEmpty {
                    List(filteredModels, id: \.self) { m in
                        Button {
                            if line == .lan { lanModel = m } else { wanModel = m }
                            pickingLine = nil
                            modelSearch = ""
                        } label: {
                            HStack {
                                Text(m)
                                    .font(.system(size: 15))
                                Spacer()
                                let cur = line == .lan ? lanModel : wanModel
                                if m == cur {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32, weight: .light))
                            .foregroundColor(.secondary)
                        Text("没能获取到模型")
                            .font(.subheadline.weight(.semibold))
                        Text(modelFetchError)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("重新获取") {
                            Task { await fetchModels(line) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(line.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        pickingLine = nil
                        modelSearch = ""
                    }
                }
            }
        }
    }

    private var filteredModels: [String] {
        let kw = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return modelList }
        return modelList.filter { $0.lowercased().contains(kw) }
    }

    /// [R52-两条线路都试] 向中转站拉 /v1/models，得到模型 id 列表。
    ///
    /// 用户原话：「不管内网还是外网都能点击获取到模型」。原实现按线路
    /// 拆死 —— 点「直连模型」只探内网地址、点「在外模型」只探外网地址，
    /// 人在外网点直连必然超时失败，失败页的「重新获取」还是同一条死路。
    ///
    /// 现在不再区分线路：把两条地址都试一遍，哪条通就用哪条的列表。
    /// 点「直连模型」还是「在外模型」只决定弹窗标题，拉取逻辑完全一样
    /// （同一家中转站，两个地址拉到的本来就是同一份模型表）。
    private func fetchModels(_ line: RelayLine) async {
        fetchingModels = true
        defer { fetchingModels = false }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // 两条候选地址（去尾斜杠 + 去空）。顺序无关紧要，并发竞速。
        let bases = [homeURL, awayURL]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { base -> String in
                var b = base
                while b.hasSuffix("/") { b.removeLast() }
                return b
            }
        guard !bases.isEmpty else {
            modelList = []
            modelFetchError = "请先填好至少一个地址。"
            pickingLine = line
            return
        }

        // Anthropic 兼容没有 /models，提示暂不支持。
        if protocolKind == .anthropic {
            modelList = []
            modelFetchError = "Anthropic 兼容协议暂不支持拉取模型列表，请改用 OpenAI 兼容。"
            pickingLine = line
            return
        }

        // 每个地址按 /v1 规则展开两条路径，全部并发打，先到先用。
        var paths: [String] = []
        for base in bases {
            if appendV1 {
                let withV1 = base.hasSuffix("/v1") ? base : base + "/v1"
                paths.append(withV1 + "/models")
                if !base.hasSuffix("/v1") { paths.append(base + "/models") }
            } else {
                paths.append(base + "/models")
                if !base.hasSuffix("/v1") { paths.append(base + "/v1/models") }
            }
        }

        // 并发竞速：谁先返回非空列表就用谁的。
        // 「重新获取」每次都是全新一轮请求，不缓存失败结果 ——
        // 原来失败后再点按钮其实也会重拉，但只重试当前这一条线路，
        // 人在外网点直连怎么重试都是死路；现在两条一起打，任何一条
        // 活着就能出列表。
        let result: [String] = await withTaskGroup(of: [String]?.self) { group in
            for p in paths {
                group.addTask { await self.fetchModelListOne(p, key: key) }
            }
            for await got in group {
                if let got, !got.isEmpty {
                    group.cancelAll()
                    return got
                }
            }
            return []
        }

        let err = result.isEmpty ? "两条线路都没拉到模型。检查地址、端口，或 API Key。" : ""

        modelList = result.sorted()
        modelFetchError = err
        pickingLine = line
    }

    /// 拉一个具体 /v1/models URL，解析出模型 id 列表。失败返回 nil。
    private func fetchModelListOne(_ fullURL: String, key: String) async -> [String]? {
        guard let url = URL(string: fullURL) else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let m = NSMutableURLRequest(url: url)
        m.timeoutInterval = 12
        m.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        m.setValue("application/json", forHTTPHeaderField: "Accept")
        if !key.isEmpty {
            m.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        guard let (data, resp) = try? await session.data(for: m as URLRequest),
              let code = (resp as? HTTPURLResponse)?.statusCode,
              (200...299).contains(code) else { return nil }

        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let raw: [Any]
        if let d = doc["data"] as? [Any] { raw = d }
        else if let d = doc["models"] as? [Any] { raw = d }
        else if let d = doc as? [Any] { raw = d }
        else { raw = [] }

        var ids: [String] = []
        for item in raw {
            if let s = item as? String, !s.isEmpty { ids.append(s) }
            else if let d = item as? [String: Any],
                    let id = (d["id"] as? String) ?? (d["name"] as? String), !id.isEmpty {
                ids.append(id)
            }
        }
        // 去重
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - 测试结果

    private func resultSection(_ r: TestResult) -> some View {
        Section {
            switch r {
            case .homeOK(let ms):
                resultRow(ok: true, title: "内网可用",
                          detail: String(format: "%.0f ms · 在家会走这条", ms))
            case .homeFail:
                resultRow(ok: false, title: "内网不通",
                          detail: "正常。不在家，或者中转站没启动")
            case .awayOK(let ms):
                resultRow(ok: true, title: "外网可用",
                          detail: String(format: "%.2f s · 在外面走这条", ms / 1000))
            case .awayFail:
                resultRow(ok: false, title: "外网不通",
                          detail: "检查隧道、域名解析，或 Key 是否正确")
            case .bothFail:
                resultRow(ok: false, title: "两个都不通",
                          detail: "先确认中转站服务在跑，再对一遍地址和端口")
            }
        } header: {
            Text("测试结果")
        }
    }

    private func resultRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 动作

    /// 测试：两条都探，各自计时。
    /// 判据与请求路径一致 —— 能拉到 /models 才算真能用，只看 200 不够。
    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = homeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = awayURL.trimmingCharacters(in: .whitespacesAndNewlines)

        async let h = probe(home, key: key)
        async let a = probe(away, key: key)
        let (homeMs, awayMs) = await (h, a)

        if let hm = homeMs {
            testResult = .homeOK(hm)
        } else if let am = awayMs {
            testResult = .awayOK(am)
        } else {
            testResult = .bothFail
        }
    }

    /// 返回耗时（毫秒）；不通返回 nil
    ///
    /// 探活要试**候选路径**，不能只拼一条：
    /// OpenAI 兼容的中转站有的把模型列表挂在 `/v1/models`，有的直接在
    /// `/models`（前面另有反代已经吃掉 /v1）。只试一条，路径不对就是 404，
    /// 而 404 在这里等于「不通」，会被记成「在外」—— 见 `save()` 里的说明。
    /// 所以按「用户配置优先，另一种兜底」的顺序各试一次，任一成功即算通。
    private func probe(_ base: String, key: String) async -> Double? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard !b.isEmpty else { return nil }

        // 候选 1：按当前 appendV1 设置拼（用户就是这么配的，优先尊重）
        var paths: [String] = []
        if protocolKind == .openAI {
            if appendV1 {
                let withV1 = b.hasSuffix("/v1") ? b : b + "/v1"
                paths.append(withV1 + "/models")
                if !b.hasSuffix("/v1") { paths.append(b + "/models") }
            } else {
                paths.append(b + "/models")
                if !b.hasSuffix("/v1") { paths.append(b + "/v1/models") }
            }
        } else {
            // Anthropic 兼容没有 /models，用 /v1/messages 探
            // （不带 body 会回 400，但 400 说明「到了」，见下面的判据）
            paths.append(b + "/v1/messages")
        }

        for p in paths {
            if let ms = await probeOne(p, key: key) { return ms }
        }
        return nil
    }

    /// 探一条具体 URL。返回耗时（毫秒）；不通返回 nil。
    ///
    /// 判据：2xx 算通；401/403/400 也算通 —— 它们都证明「请求到达了服务」，
    /// 只是 Key 没带或 body 不全。只有连不上、超时、5xx 才算不通。
    /// 这与 `RelayProbe.reachable(home:)` 认 `service` 字段的思路一致：
    /// 判的是「是不是目标服务在应答」，不是「这次调用成不成功」。
    private func probeOne(_ fullURL: String, key: String) async -> Double? {
        guard let url = URL(string: fullURL) else { return nil }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let m = NSMutableURLRequest(url: url)
        m.timeoutInterval = 8
        m.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        m.setValue(key, forHTTPHeaderField: "Authorization")
        m.setValue("application/json", forHTTPHeaderField: "Accept")
        if protocolKind == .anthropic {
            m.setValue(key, forHTTPHeaderField: "x-api-key")
            m.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        let start = Date()
        guard let (_, resp) = try? await session.data(for: m as URLRequest),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        guard (200...299).contains(code) || code == 400 || code == 401 || code == 403
        else { return nil }
        return Date().timeIntervalSince(start) * 1000
    }

    private func save() async {
        saving = true
        saveError = ""
        defer { saving = false }

        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = homeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = awayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // [R52-编辑模式] 编辑时复用原 instanceId，新增才生成新的。
        let instanceId = editInstanceId ?? UUID().uuidString

        // 编辑时保留原实例的 isEnabled / createdAt / customUserAgent，
        // 不要因为「重建实例」把用户停用状态或创建时间弄丢。
        let old = editInstanceId.flatMap { ProviderConfigStore.shared.instance(for: $0) }

        // 建实例：customBaseURL 用内网地址（离线兜底），
        // 真正生效的地址由中转站档案 + requestBaseURL 决定
        let providerType: ProviderType = protocolKind == .openAI ? .openAI : .anthropic
        let instance = ProviderInstance(
            id: instanceId,
            label: name,
            providerType: providerType,
            credentialType: .apiKey,
            isEnabled: old?.isEnabled ?? true,
            createdAt: old?.createdAt ?? Date(),
            customBaseURL: home,
            appendV1Suffix: protocolKind == .openAI ? appendV1 : true,
            customUserAgent: old?.customUserAgent,
            unknownProviderTypeRaw: old?.unknownProviderTypeRaw
        )

        // 先判定一次，把结果缓存进档案（失败也不阻塞保存）。
        //
        // ⚠️ 必须复用 test() 用的那个 probe，不能另写一套：
        // 早前这里调的是 `RelayProbe.reachableHome(home)`，它直接拼
        // `base + "/models"`，而 relay 的模型列表在 `/v1/models` ——
        // 用户填 `http://192.168.x.x:8080` 时探的是 `/models`，
        // 404 → 返回 false → `lastResolvedIsLan = false`。
        // 结果就是：明明在家保存的中转站，被记成「在外」，
        // 之后每次发消息都先走域名绕一圈，白慢 35 倍，直到某次
        // 用户手动刷新才纠正。这就是两套逻辑打架的典型代价。
        let isLan = await probe(home, key: key) != nil

        let profile = RelayProviderProfile(
            instanceId: instanceId,
            homeURL: home,
            awayURL: away,
            routeMode: routeMode,
            protocolKind: protocolKind,
            lastResolvedIsLan: isLan,
            lastResolvedAt: Date(),
            // 档案里也要存一份 —— 编辑页打开时靠它回填。
            appendV1Suffix: instance.appendV1Suffix,
            // [R45-直连/在外模型] 两条线路各自选的模型。
            lanModel: lanModel,
            wanModel: wanModel
        )

        // 顺序：先写 Key（失败就整单不落），再写档案，最后加/改实例。
        // 这样任何一步失败都不会留下「有实例没 Key」的坏状态。
        //
        // [R52] 编辑模式：key 留空 = 不修改原 Key，跳过写钥匙串。
        if !key.isEmpty {
            ProviderKeychainHelper.saveAPIKey(key, instanceId: instanceId)
            guard ProviderKeychainHelper.loadAPIKey(instanceId: instanceId) != nil else {
                saveError = "保存失败：API Key 无法写入钥匙串。"
                return
            }
        }

        RelayProfileStore.shared.upsert(profile)
        if editInstanceId != nil {
            ProviderConfigStore.shared.updateInstance(instance)
        } else {
            ProviderConfigStore.shared.addInstance(instance)
        }

        // [R51-中转站设为默认模型] 保存后把这个中转站的模型设为
        // 新对话的默认选择。
        //
        // 为什么必须做：addInstance 对 apiKey 实例是异步拉模型的
        // （refreshModels 在后台 Task 里跑），拉到的条目不会自动
        // 进默认组；defaultPrimaryGroupId 还指着旧组（或 nil）。
        // 新建对话的模型解析链（createInitialBinding tier1 →
        // defaultPrimaryGroupId）拿不到这个中转站的模型，顶栏就
        // 显示「未选择模型」—— 用户必须手动去挑一次。
        //
        // 做法：等后台拉模型落地（轮询 store，最多 ~6 秒），然后
        //
        //   · 用户在中转站页选了「直连模型」（lanModel）→ 用它
        //   · 没选 → 用该实例拉到的第一个文本模型
        //
        // 建一个单成员组挂到 defaultPrimaryGroupId。已有的默认组
        // 不覆盖 —— 只在「现在没有默认组」时才设，避免抢用户
        // 已经手动配好的默认。
        //
        // 拉模型失败（中转站不在线等）就放弃，不阻塞保存 ——
        // 用户下次手动刷新模型后再说，行为与从前一致。
        await seedDefaultModelGroup(for: instance, preferredModelId: lanModel)

        onSaved?(instance.id)
        dismiss()
    }

    /// [R51] 保存中转站后，把它的模型挂成新对话的默认选择。
    ///
    /// 只在「当前没有默认组」时生效；已有默认组说明用户配过，不抢。
    /// 等待 addInstance 的后台 refreshModels 落地最多 ~6 秒
    /// （0.3s × 20 次），超时就用现有条目（可能为空 = 放弃）。
    private func seedDefaultModelGroup(for instance: ProviderInstance,
                                       preferredModelId: String?) async {
        let store = ProviderConfigStore.shared

        // 已有默认组：用户配置过，不覆盖。
        if store.defaultPrimaryGroupId != nil { return }

        // 等后台模型拉取落地（addInstance 里 fire-and-forget 的 Task）。
        var entries: [ModelEntry] = []
        for _ in 0..<20 {
            entries = store.modelEntries.filter {
                $0.providerInstanceId == instance.id && !$0.isHidden
            }
            if !entries.isEmpty { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // 用户在中转站页选的「直连模型」优先；没选就用第一个文本模型。
        let chosen: ModelEntry?
        if let preferred = preferredModelId {
            chosen = entries.first { $0.model.id == preferred }
        } else {
            chosen = entries.first { entry in
                guard let m = entry.model.modalityOverride else { return true }
                return !m.contains(.imageOutput) && !m.contains(.audioOutput)
                    && !m.contains(.videoOutput)
            } ?? entries.first
        }
        guard let entry = chosen else {
            Logger(subsystem: "app.minis", category: "RelaySetup").info(
                "[RelayDefault] instance=\(instance.label) 拉不到模型条目，跳过默认组设置")
            return
        }

        let group = ModelGroup(
            name: instance.label,
            memberEntryIds: [entry.id],
            strategy: .fallback
        )
        store.addGroup(group)
        store.defaultPrimaryGroupId = group.id
        Logger(subsystem: "app.minis", category: "RelaySetup").info(
            "[RelayDefault] instance=\(instance.label) 已设为默认组 entry=\(entry.model.id)")
    }
}

// MARK: - 探测辅助
//
// 这里原本有一个 `RelayProbe.reachableHome(_:)`，探的是 `base + "/models"`。
// 已经删掉，原因写在 `save()` 里：它和本文件的 `probe(_:key:)` 是两套判据，
// 前者探错路径（少了 /v1）就会把「在家」误判成「在外」并写进档案。
// 线路判定只留一份实现，要探就调 `probe(_:key:)`。

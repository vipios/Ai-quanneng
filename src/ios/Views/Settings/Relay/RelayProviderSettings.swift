//
//  RelayProviderSettings.swift
//  Minis — 「添加 AI 中转站」配置存储
//
//  ============================================================
//  与普通 Provider 的区别
//
//  普通 Provider 只有一个 customBaseURL。中转站有**两个**地址：
//    · 内网地址（在家直连，快 35 倍）
//    · 外网地址（在外面走域名/隧道）
//  请求时按当前网络自动选一个。
//
//  ============================================================
//  怎么把「双地址」塞进现有 Provider 体系
//
//  不新增 ProviderType，也不改 ProviderInstance 的存储结构 —— 那样会
//  波及同步、迁移、导入导出、几十处 switch。
//
//  做法：用「中转站档案」旁挂一份配置，key 是 ProviderInstance.id。
//
//    · ProviderInstance.credentialType = .apiKey（照常存 Key）
//    · ProviderInstance.customBaseURL  = 内网地址（默认值，也是离线兜底）
//    · RelayProviderProfile[instanceId] = { homeURL, awayURL, routeMode }
//
//  然后在 ProviderInstance.resolvedBaseURL(default:) 这一个唯一收口处，
//  按当前线路把 customBaseURL 换成生效地址。所有请求都经过那里，
//  所以不需要改任何调用方。
//
//  ============================================================
//  为什么必须能在「没探测过」的情况下也工作
//
//  判定要 1.2 秒超时。如果用户刚打开 App 就发消息，判定可能还没完成。
//  这时必须有个确定答案 —— 用 routeMode 的偏好值，而不是等。
//  ============================================================
//

import Foundation

// MARK: - 线路偏好

enum RelayRouteMode: String, Codable, CaseIterable, Identifiable {
    /// 自动判定：探内网通不通，通就直连，不通走域名
    case auto
    /// 永远走内网（家里固定网络用，省掉探测延迟）
    case homeOnly
    /// 永远走外网（在公司/外出固定用）
    case awayOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:     return "自动判定"
        case .homeOnly: return "只用内网"
        case .awayOnly: return "只用外网"
        }
    }

    var subtitle: String {
        switch self {
        case .auto:     return "进页面时探测内网，通就直连，不通走域名"
        case .homeOnly: return "跳过探测，永远直连。适合一直在家"
        case .awayOnly: return "跳过探测，永远走域名。适合一直不在家"
        }
    }

    var icon: String {
        switch self {
        case .auto:     return "arrow.triangle.branch"
        case .homeOnly: return "house.fill"
        case .awayOnly: return "globe.asia.australia.fill"
        }
    }
}

// MARK: - 单个中转站档案

struct RelayProviderProfile: Codable, Equatable {
    /// ProviderInstance.id
    var instanceId: String
    /// 内网地址，带协议与端口，例如 http://192.168.x.x:8080
    var homeURL: String
    /// 外网地址，带协议，例如 https://xxx.dpdns.org
    var awayURL: String
    /// 线路偏好
    var routeMode: RelayRouteMode
    /// 协议类型（OpenAI 兼容 / Anthropic 兼容）—— 决定建实例时用哪种 providerType
    var protocolKind: RelayProtocolKind
    /// 上次判定的结果（只是缓存，用于界面显示与离线兜底）
    var lastResolvedIsLan: Bool?
    var lastResolvedAt: Date?
    /// 建实例时是否给 base URL 自动追加 `/v1`。
    ///
    /// 为什么必须存进档案：建实例时 `ProviderInstance.appendV1Suffix` 会写一次，
    /// 但那个值之后就被实例自己拿着，档案这边是空的。现在没有「编辑中转站」
    /// 的入口，所以看不出问题；一旦加了编辑页，打开时会拿不到原值，
    /// 只能显示一个默认的 true —— 用户当初设的是 false 也会被悄悄改回来，
    /// 表现为「编辑一次就发不出消息了」。
    ///
    /// 有默认值 `true` 且是可选解码：老档案（这个字段还不存在时写下的）
    /// 仍能正常读出来，不会因为新增字段让 `JSONDecoder` 整个失败、
    /// 把用户已配好的中转站全部丢掉。
    var appendV1Suffix: Bool? = nil

    /// [R45-直连/在外模型] 直连线路（内网）用的模型 id，纯字符串。
    ///
    /// 来自用户在中转站表单里「点箭头 → 拉该线路 /v1/models → 选中」的结果。
    /// 不存 LLMModel 对象、也不进 ProviderConfigStore 的模型体系 —— 这是
    /// **中转站专属的请求级覆盖**：发消息时把请求体 `model` 字段替换成它，
    /// 和 App 原版的 ModelEntry/ModelGroup 是两套独立的东西。
    ///
    /// 可选解码：老档案没有这字段时解码为 nil，覆盖逻辑自动跳过（不覆盖）。
    var lanModel: String? = nil
    /// 在外线路（外网）用的模型 id。语义同 `lanModel`。
    var wanModel: String? = nil

    /// 取「要不要追加 /v1」，老档案没有这个字段时给 true（与建实例时的默认一致）
    var effectiveAppendV1: Bool { appendV1Suffix ?? true }

    /// 按当前线路取要覆盖的模型 id。
    ///
    /// 规则（与设计稿一致）：
    ///   · 当前线路已选 → 用该线路的模型；
    ///   · 当前线路未选 → 回落到另一条已选模型；
    ///   · 两条都没选 → 返回 nil（不覆盖，走 App 原版 model）。
    func modelForRoute(isLan: Bool) -> String? {
        let primary = isLan ? lanModel : wanModel
        let fallback = isLan ? wanModel : lanModel
        return Self.nonEmpty(primary) ?? Self.nonEmpty(fallback)
    }

    /// 当前**生效**线路是不是内网。口径与 `effectiveURL()` 完全一致 ——
    /// auto 模式看 `lastResolvedIsLan`（未判过默认外网），homeOnly 恒内网，
    /// awayOnly 恒外网。供镜像表算「当前该用哪个模型」。
    func resolvedIsLan() -> Bool {
        switch routeMode {
        case .homeOnly:
            return true
        case .awayOnly:
            return false
        case .auto:
            return lastResolvedIsLan ?? false
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let v = s?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return nil
        }
        return v
    }

    /// 生效地址。判定缓存优先，没判过就按偏好值给一个确定答案。
    func effectiveURL() -> String {
        switch routeMode {
        case .homeOnly:
            return homeURL
        case .awayOnly:
            return awayURL
        case .auto:
            if let lan = lastResolvedIsLan {
                return lan ? homeURL : awayURL
            }
            // 还没判过（老数据迁移上来 / 刚导入 / 判定还没跑完）。
            //
            // 这里必须默认**外网**，不能默认内网：
            //   · 域名的 Cloudflare 隧道在家里也是通的，只是绕一圈慢几秒；
            //   · 内网地址在外面**根本不通**，请求直接失败。
            // 所以「不确定时选外网」是唯一不会让用户发不出消息的选择 ——
            // 慢一点是可接受的降级，发不出去不是。
            // 之前这里默认 homeURL，用户在外面第一次发消息必然失败一次，
            // 看起来就像「中转站坏了」。
            let away = awayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !away.isEmpty { return away }
            return homeURL
        }
    }
}

// MARK: - 兼容协议

enum RelayProtocolKind: String, Codable, CaseIterable, Identifiable {
    case openAI
    case anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI:    return "OpenAI 兼容"
        case .anthropic: return "Anthropic 兼容"
        }
    }

    var subtitle: String {
        switch self {
        case .openAI:    return "走 /v1/chat/completions、/v1/models"
        case .anthropic: return "走 /v1/messages"
        }
    }
}

// MARK: - 档案仓库

/// 中转站档案的唯一读写入口。
///
/// 落盘位置：与 Provider 配置同一个 library 目录下的 `relay-profiles.json`。
/// 刻意不放进 UserDefaults —— 它需要被备份/导出覆盖到，放在 library
/// 目录里和 provider-config.json 同域，备份逻辑天然带上。
///
/// ⚠️ 不加 @MainActor、也不做 ObservableObject。原因：
///    `ProviderInstance.requestBaseURL` 是同步属性，在请求构造的后台线程上
///    被读取；Swift 5 模式下从非隔离上下文访问 MainActor 类型会报隔离错误。
///    这里用 NSLock 自己保证线程安全，比把整个请求路径改成 async 干净得多。
///    界面如果将来要展示档案列表，读 `allProfiles()` 拿一份快照即可。
final class RelayProfileStore {

    static let shared = RelayProfileStore()

    /// 加锁的真实存储。请求路径与写入路径都读写它。
    private var storage: [String: RelayProviderProfile] = [:]

    private let fileURL: URL
    private let lock = NSLock()
    // 这里原来有个 ioQueue 做异步落盘，现在 persist() 改成同步写，已删除。

    private init() {
        let lib = FileManager.default.urls(for: .libraryDirectory,
                                           in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = lib.appendingPathComponent("MinisChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("relay-profiles.json")
        loadFromDisk()
    }

    // MARK: 读

    func profile(for instanceId: String) -> RelayProviderProfile? {
        lock.lock()
        defer { lock.unlock() }
        return storage[instanceId]
    }

    func isRelay(_ instanceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[instanceId] != nil
    }

    // MARK: - [R66-档案丢失自愈] 实例在、档案不在

    /// 这个实例**看起来**是不是一台中转站 —— 不看档案，只看实例本身。
    ///
    /// 为什么需要它：中转站的双地址 / 线路模型住在 `relay-profiles.json`
    /// 这个旁挂文件里，而**备份、iCloud 同步、「导出服务商」JSON 都只带
    /// provider-config.json，不带它**。于是「换设备 / 恢复备份 / 导入服务商」
    /// 之后会出现一种很隐蔽的半截状态：
    ///   · ProviderInstance 还在，发消息照常通（回落到实例自己的 customBaseURL）
    ///   · 档案全丢 → 内网直连 / 在外走域名 / 两条线路各自选模型全部失效
    ///   · 详情页的「编辑」按钮也消失（它的显示条件就是「有档案」）
    /// 界面上只表现为「少了一个按钮」，用户根本想不到是数据丢了。
    ///
    /// 判定口径刻意收得很窄，只认**内网地址**：
    ///   · 私网 IPv4（10/8、172.16/12、192.168/16）、127.0.0.1、localhost
    ///   · 且必须是 apiKey + OpenAI/Anthropic 兼容类型
    /// 公网域名的自定义服务商（api.deepseek.com 之类）不会被误判成中转站。
    ///
    /// `.openAIResponses` 也要认：详情页的「API 格式」开关会把 .openAI 改写成
    /// .openAIResponses（id 不变），中转站用户切过一次格式就会被漏掉。
    static func looksLikeRelay(_ instance: ProviderInstance) -> Bool {
        guard instance.credentialType == .apiKey else { return false }
        switch instance.providerType {
        case .openAI, .openAIResponses, .anthropic:
            break
        default:
            return false
        }
        guard let url = instance.effectiveCustomBaseURL else { return false }
        return isPrivateHost(url)
    }

    /// URL 里的主机名是不是内网地址。
    static func isPrivateHost(_ url: String) -> Bool {
        // 不引 URLComponents：用户可能填 `192.168.1.88:8080`（没写协议），
        // URLComponents 会把整串当 path，这里手工抠 host 更稳。
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
        }
        // 去掉 path / query / fragment
        for sep in ["/", "?", "#"] {
            if let i = s.firstIndex(of: Character(sep)) {
                s = String(s[..<i])
            }
        }
        // 去掉 user:pass@
        if let at = s.lastIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }
        // 去掉端口（IPv6 的 [::1]:8080 这种先不处理 —— 家用中转站不是 v6 字面量）
        if let colon = s.lastIndex(of: ":") {
            s = String(s[..<colon])
        }
        guard !s.isEmpty else { return false }
        if s == "localhost" { return true }

        let parts = s.split(separator: ".")
        guard parts.count == 4,
              let a = Int(parts[0]), let b = Int(parts[1]),
              (0...255).contains(a), (0...255).contains(b) else { return false }
        if a == 10 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 127 { return true }
        return false
    }

    /// 把「实例在、档案不在」的中转站补回档案（只补能确定的部分）。
    ///
    /// 补出来的档案：homeURL = 实例自己的 customBaseURL，awayURL 空，
    /// 线路 .auto（空 away 时 `effectiveURL()` 会自动回落到 homeURL，
    /// 所以补完的请求行为和补之前完全一致 —— 不会因为自愈反而发不出消息），
    /// 线路模型留空（不覆盖，走 App 原版 model）。
    ///
    /// 在外地址补不出来（那本来就是只存在档案里的东西），留在空位上，
    /// 用户点「编辑」填一次就有了。
    ///
    /// 返回补了几条；0 表示没有需要处理的（调用方据此跳过落盘）。
    @discardableResult
    func healMissingProfiles(from instances: [ProviderInstance]) -> Int {
        var healed = 0
        for inst in instances {
            guard Self.looksLikeRelay(inst) else { continue }
            lock.lock()
            let exists = storage[inst.id] != nil
            lock.unlock()
            guard !exists else { continue }
            guard let home = inst.effectiveCustomBaseURL else { continue }

            let kind: RelayProtocolKind = (inst.providerType == .anthropic) ? .anthropic : .openAI
            upsert(RelayProviderProfile(
                instanceId: inst.id,
                homeURL: home,
                awayURL: "",
                routeMode: .auto,
                protocolKind: kind,
                lastResolvedIsLan: nil,
                lastResolvedAt: nil,
                appendV1Suffix: inst.appendV1Suffix,
                lanModel: nil,
                wanModel: nil
            ))
            healed += 1
        }
        return healed
    }

    /// 同步取生效地址。**必须同步** —— 请求构造路径上不能 async。
    /// 与 `ProviderInstance.requestBaseURL` 走的是同一个镜像表。
    nonisolated func effectiveURL(for instanceId: String) -> String? {
        RelayProfileMirror.shared.url(for: instanceId)
    }

    /// 同步取「当前线路该用哪个模型 id」。
    ///
    /// 请求构造路径（`LLMProviderFactory.makeProvider`）上不能 async，
    /// 所以这里走加锁镜像表。返回 nil 表示该中转站没配线路模型，
    /// 不覆盖、走 App 原版 model。
    nonisolated func overrideModelId(for instanceId: String) -> String? {
        RelayProfileMirror.shared.modelId(for: instanceId)
    }

    // MARK: 写

    func upsert(_ profile: RelayProviderProfile) {
        lock.lock()
        storage[profile.instanceId] = profile
        lock.unlock()
        // 镜像由 persist() 统一重建，这里不再手动 set —— 见 persist() 的注释。
        persist()
    }

    func updateResolution(instanceId: String, isLan: Bool) {
        lock.lock()
        guard var p = storage[instanceId] else {
            lock.unlock()
            return
        }
        p.lastResolvedIsLan = isLan
        p.lastResolvedAt = Date()
        storage[instanceId] = p
        lock.unlock()

        persist()
    }

    func remove(instanceId: String) {
        lock.lock()
        storage.removeValue(forKey: instanceId)
        lock.unlock()

        persist()
    }

    /// 给界面用的一份快照（不含锁外引用）
    func allProfiles() -> [RelayProviderProfile] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storage.values)
    }

    // MARK: 落盘

    private struct FileShape: Codable {
        var version: Int
        var profiles: [RelayProviderProfile]
    }

    /// 从磁盘读。init 阶段调用 —— 此时 `self` 还没对外可见，
    /// 所以直接写存储字段，再重建镜像。
    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let shape = try? JSONDecoder().decode(FileShape.self, from: data) else {
            return
        }
        var map: [String: RelayProviderProfile] = [:]
        for p in shape.profiles { map[p.instanceId] = p }

        storage = map
        rebuildMirror(from: Array(map.values))
    }

    /// 从 storage 快照全量重建 `RelayProfileMirror`。
    ///
    /// 只有这一个地方写 mirror，两个入口（读盘、落盘）都走它。
    /// 之前是「每个写调用点各自 set/remove」，漏一处就是
    /// 「界面显示新地址、请求还打旧地址」，查起来极费劲。
    private func rebuildMirror(from list: [RelayProviderProfile]) {
        var urls: [String: String] = [:]
        var models: [String: String] = [:]
        for p in list {
            urls[p.instanceId] = p.effectiveURL()
            // 已按当前线路解析好的最终模型（nil 表示没配，不覆盖）
            if let m = p.modelForRoute(isLan: p.resolvedIsLan()) {
                models[p.instanceId] = m
            }
        }
        RelayProfileMirror.shared.replaceAll(urls, models: models)
    }

    /// 落盘。
    ///
    /// ⚠️ 这里**同步写**，不是异步。
    ///
    /// 原来用的是 `ioQueue.async { data.write(...) }`，理由是「不卡主线程」。
    /// 但档案总共几 KB（最多几个中转站），一次 `write(.atomic)` 是零点几毫秒，
    /// 主线程完全无感。而异步的代价是真实的：
    ///   · 用户改完地址、切后台、被系统干掉 —— 最后一次修改直接丢
    ///   · iOS 从后台恢复时杀进程很常见，不是小概率事件
    ///   · 丢的是「刚改的线路地址」，下次打开就在错误的线路上请求
    /// 用丢数据换零点几毫秒，不划算。
    ///
    /// 顺带重建镜像表 —— 理由见 `rebuildMirror(from:)`。
    private func persist() {
        lock.lock()
        let list = Array(storage.values)
        lock.unlock()

        // 顺序放在编码/落盘**之前**：编码理论上不该失败（字段都是 String/Bool/Date），
        // 但真失败了也不能让「内存已改、请求路径还是旧地址」这种半截状态存在。
        // 内存里的语义一致性优先于磁盘。
        rebuildMirror(from: list)

        let shape = FileShape(version: 1, profiles: list)
        guard let data = try? JSONEncoder().encode(shape) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - 请求路径用的只读镜像

/// `RelayProfileStore` 是 @MainActor 的，但请求构造发生在后台线程。
/// 这里维护一份加锁的 instanceId → 生效地址 映射，供请求路径同步读取。
final class RelayProfileMirror {

    static let shared = RelayProfileMirror()
    private init() {}

    private var map: [String: String] = [:]
    /// instanceId → 已按当前线路解析好的最终模型 id。没有 = 该中转站没配线路模型。
    private var modelMap: [String: String] = [:]
    private let lock = NSLock()

    func url(for instanceId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return map[instanceId]
    }

    /// 取当前线路该用的模型 id。nil = 没配，不覆盖。
    func modelId(for instanceId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return modelMap[instanceId]
    }

    /// 全量替换。**这是唯一的写入口** —— 没有单条 `set` / `remove`。
    ///
    /// 故意不给单条写：给了就又会变成「哪个调用点忘了同步」，而那正是
    /// 这次要消灭的 bug 类型。调用方统一从 `storage` 拿全量快照重建，
    /// 数量是个位数，没有性能问题。
    func replaceAll(_ new: [String: String], models: [String: String]) {
        lock.lock()
        map = new
        modelMap = models
        lock.unlock()
    }
}

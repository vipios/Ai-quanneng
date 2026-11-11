//
//  RelayBackend.swift
//  Minis — 中转站后台接口 + 路由器指令
//
//  两个接口族：
//    · Backend  —— relay.py 的 /admin/api/*（设备状态、重启路由器）
//    · Router   —— uhttpd 的 /cgi-bin/airboot（只重启中转站 / 重启整机）
//
//  字段按设备实测返回写死（relay.py 的 /admin/api/device）：
//    {"uptime":34530,"uptime_text":"9 小时 35 分钟","mem_total_kb":119220,
//     "mem_avail_kb":13732,"swap_used_pct":77,"load":[1.04,0.69,0.67],
//     "relay_rss_kb":11836,"should_reboot":false}
//
//  任何一个字段缺失都给默认值，绝不因为少一个字段就整张卡报错。
//
//  ⚠️ 这里刻意用 NSMutableURLRequest 而不是 URLRequest 的 Swift 属性 setter：
//     `req.httpMethod = ...` / `req.timeoutInterval = ...` 在旧系统 Foundation
//     里是**缺失的 ABI 符号**，调用即 dyld: Symbol not found，App 启动就闪退。
//     ObjC 消息跨 iOS 14–17 稳定，所以走 mutableCopy。
//

import Foundation

// MARK: - 设备状态

struct RelayDeviceStatus {
    var uptimeText = "—"
    var memTotalKB = 0
    var memAvailKB = 0
    var swapUsedPct: Double = 0
    var load: [Double] = []
    var relayRssKB = 0
    var shouldReboot = false
    var canReboot = false

    var memAvailText: String {
        guard memAvailKB > 0 else { return "—" }
        let mb = Double(memAvailKB) / 1024
        let total = memTotalKB > 0 ? String(format: "/%.0fM", Double(memTotalKB) / 1024) : ""
        return String(format: "%.0fM%@", mb, total)
    }

    /// 这台设备可用内存经常只有 13MB，低于 20MB 就是真的紧张了
    var memLow: Bool { memAvailKB > 0 && memAvailKB < 20 * 1024 }

    var swapText: String {
        String(format: "%.0f%%", swapUsedPct)
    }

    /// 交换内存用到 70% 以上，基本就是要「后台进不去、一直转圈」的前兆
    var swapHigh: Bool { swapUsedPct >= 70 }

    var loadText: String {
        guard let f = load.first else { return "—" }
        return String(format: "%.2f", f)
    }

    /// 单核设备，负载 >1 就是吃满了
    var loadHigh: Bool { (load.first ?? 0) > 1.0 }

    var relayRssText: String {
        guard relayRssKB > 0 else { return "—" }
        return String(format: "%.0f MB", Double(relayRssKB) / 1024)
    }

    /// 该不该重启 —— 后端给了就用后端的，没给按本地阈值推
    /// （内存 < 20MB 或 swap ≥ 70% 就该重启了）
    var recommendReboot: Bool {
        if shouldReboot { return true }
        return memLow || swapHigh
    }

    /// 一句人话说明「为什么建议重启」，没有症状返回 nil
    var rebootReason: String? {
        if memLow && swapHigh { return "可用内存 \(memAvailText)，交换已用到 \(swapText)" }
        if memLow { return "可用内存只剩 \(memAvailText)" }
        if swapHigh { return "交换内存已用到 \(swapText)" }
        if shouldReboot { return "后台报告需要重启" }
        return nil
    }
}

// MARK: - 错误

enum RelayError: LocalizedError {
    case noKey
    case badHost
    case badKey
    case notLan
    case badReply
    case http(Int)
    case rejected(String)
    case offline

    var isBadKey: Bool {
        if case .badKey = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .noKey:            return "还没填密钥。路由器重启要 airboot 的密钥，填一次就一直记住。"
        case .badHost:          return "地址格式不对。"
        case .badKey:           return "密钥不对。"
        // A6：airboot 里 `lan-only` 这个错误码是真实存在的（某些动作路由器端
        // 确实只放行内网）。所以判据保留，只把话改准：是「这条指令」要求
        // 在家直连，不是「所有操作」都要求 —— 别的动作在外走隧道照样能做，
        // 原来说「这个操作只能在家里」会让人以为整个设备管理都白配了。
        case .notLan:           return "这条指令要求在家直连。换个网络再试，或到家里连着 WiFi 再点。"
        case .badReply:         return "设备回了看不懂的内容。"
        case .http(let c):      return "返回 HTTP \(c)。"
        case .rejected(let e):  return "设备拒绝了：\(e)"
        case .offline:          return "连不上设备。"
        }
    }
}

// MARK: - 中转站后台

enum RelayBackend {

    /// 必须带正常 UA：中转站前面挂着 Cloudflare，裸 UA 会被 1010 拒掉
    private static var userAgent: String {
        "Minis/\(RelayDeviceInfo.appVersion) CFNetwork/1410.0.3 Darwin/22.6.0"
    }

    private static func makeURL(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard !b.isEmpty else { return nil }
        return URL(string: b + path)
    }

    private static func request(_ url: URL, key: String?, timeout: TimeInterval,
                                method: String = "GET",
                                body: Data? = nil) -> URLRequest {
        let mutable = NSMutableURLRequest(url: url)
        mutable.httpMethod = method
        mutable.timeoutInterval = timeout
        mutable.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        mutable.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        mutable.setValue("application/json", forHTTPHeaderField: "Accept")
        if let b = body {
            mutable.httpBody = b
            mutable.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let k = key, !k.isEmpty {
            mutable.setValue(k, forHTTPHeaderField: "X-Access-Key")
        }
        return mutable as URLRequest
    }

    /// 拉设备状态。失败给一句人话，页面直接展示。
    static func fetchDevice(base: String, key: String) async -> Result<RelayDeviceStatus, RelayError> {
        guard let url = makeURL(base, "/admin/api/device") else { return .failure(.badHost) }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        guard let (data, resp) = try? await session.data(for: request(url, key: key, timeout: 10)),
              let code = (resp as? HTTPURLResponse)?.statusCode
        else { return .failure(.offline) }

        if code == 401 || code == 403 { return .failure(.badKey) }
        guard (200...299).contains(code) else { return .failure(.http(code)) }
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.badReply)
        }

        var d = RelayDeviceStatus()
        if let t = doc["uptime_text"] as? String, !t.isEmpty { d.uptimeText = t }
        d.memTotalKB   = intValue(doc["mem_total_kb"])
        d.memAvailKB   = intValue(doc["mem_avail_kb"])
        d.swapUsedPct  = doubleValue(doc["swap_used_pct"])
        if let arr = doc["load"] as? [Any] {
            d.load = arr.compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        d.relayRssKB   = intValue(doc["relay_rss_kb"])
        d.shouldReboot = (doc["should_reboot"] as? Bool) ?? false
        d.canReboot    = (doc["can_reboot"] as? Bool) ?? false
        return .success(d)
    }

    /// 密码对不对 —— 用 /admin/api/device 探，因为它必须带密钥。
    ///
    /// 判定原则：只有明确 401/403 才判「密码错」。
    /// 连不上（超时/0/5xx）不能判成密码错，否则用户会被引导去改一个本来正确的密码。
    static func verifyKey(base: String, key: String) async -> Bool {
        guard let url = makeURL(base, "/admin/api/device") else { return false }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        guard let (_, resp) = try? await session.data(for: request(url, key: key, timeout: 8)) else {
            // 完全连不上：既不能说他密码错，也不能放行存起来。
            // 让上层提示「密码不对，或者连不上设备」—— 两种情况都不该保存。
            return false
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { return false }
        if (200...299).contains(code) { return true }
        return false
    }

    /// 重启路由器。**必须带 {"confirm":"reboot"}**，否则后端拒绝。
    /// 后端先回包再延迟 2 秒重启，所以这里拿到 200 就算成功。
    static func rebootRouter(base: String, key: String,
                             timeout: TimeInterval = 20) async throws {
        guard let url = makeURL(base, "/admin/api/device/reboot") else { throw RelayError.badHost }
        let body = Data(#"{"confirm":"reboot"}"#.utf8)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let (data, resp) = try await session.data(
            for: request(url, key: key, timeout: timeout, method: "POST", body: body))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0

        if code == 401 || code == 403 { throw RelayError.badKey }
        // 5xx 也算「发下去了」：设备重启时来不及回干净包
        if code >= 500 { return }
        guard (200...299).contains(code) else { throw RelayError.http(code) }

        if let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (doc["ok"] as? Bool) == false {
            throw RelayError.rejected((doc["err"] as? String) ?? "rejected")
        }
    }

    // MARK: 数值兜底

    /// 后端可能给 Int，也可能给 Double，也可能给字符串
    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let i = Int(s) { return i }
        return 0
    }

    private static func doubleValue(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String, let d = Double(s) { return d }
        return 0
    }
}

// MARK: - 路由器指令（airboot）

enum RelayRouter {

    static let bootPath = "/cgi-bin/airboot"

    /// 探活：这个地址上是不是我们的路由器。
    /// 判据是 `svc == "airboot"` —— 别人家不可能有这个字段。
    static func ping(route: RelayRoute, timeout: TimeInterval = 2.5) async -> Bool {
        guard let u = bootURL(base: route.bootBase, query: "action=ping") else { return false }
        guard let doc = await json(u, timeout: timeout) else { return false }
        return (doc["ok"] as? Bool) == true && (doc["svc"] as? String) == "airboot"
    }

    /// 只重启中转站进程 —— WiFi 不断
    static func restartRelay(route: RelayRoute, key: String,
                             timeout: TimeInterval = 10) async throws {
        try await send(action: "relay", route: route, key: key, timeout: timeout)
    }

    /// 重启整台路由器 —— 家里所有设备断网约 1 分钟
    static func reboot(route: RelayRoute, key: String,
                       timeout: TimeInterval = 10) async throws {
        try await send(action: "reboot", route: route, key: key, timeout: timeout)
    }

    private static func json(_ url: URL, timeout: TimeInterval) async -> [String: Any]? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 0.8
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let m = NSMutableURLRequest(url: url)
        m.timeoutInterval = timeout
        m.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        m.setValue("Minis/\(RelayDeviceInfo.appVersion) CFNetwork/1410.0.3 Darwin/22.6.0",
                   forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await session.data(for: m as URLRequest),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func send(action: String, route: RelayRoute, key: String,
                            timeout: TimeInterval) async throws {
        guard !key.isEmpty else { throw RelayError.noKey }
        guard let u = bootURL(base: route.bootBase,
                              query: "action=" + action + "&k=" + escaped(key)) else {
            throw RelayError.badHost
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let m = NSMutableURLRequest(url: u)
        m.timeoutInterval = timeout
        m.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        m.setValue("Minis/\(RelayDeviceInfo.appVersion) CFNetwork/1410.0.3 Darwin/22.6.0",
                   forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await session.data(for: m as URLRequest)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 500/502 也算成功：脚本已经把 reboot exec 出去了，uhttpd 等不到输出才报错
        if code != 200 && code != 500 && code != 502 { throw RelayError.http(code) }
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if code == 500 || code == 502 { return }
            throw RelayError.badReply
        }
        if (doc["ok"] as? Bool) == true { return }
        let err = (doc["err"] as? String) ?? ""
        switch err {
        case "bad-key", "no-token": throw RelayError.badKey
        case "lan-only":            throw RelayError.notLan
        default:                    throw RelayError.rejected(err)
        }
    }

    // MARK: 工具

    /// 拼 airboot 的 URL。用户填的 host 可能带协议、带斜杠，这里统一收口。
    static func bootURL(base: String, query: String) -> URL? {
        var h = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while h.hasSuffix("/") { h.removeLast() }
        guard !h.isEmpty else { return nil }
        if !h.contains("://") { h = "http://" + h }
        return URL(string: h + bootPath + "?" + query)
    }

    static func escaped(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

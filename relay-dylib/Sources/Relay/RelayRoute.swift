//
//  RelayRoute.swift
//  Minis — 中转站 / 路由器线路判定
//
//  这套判定逻辑来自 Cabin（2026-11-08 真机实测），结论已固化，**不要再改**。
//
//  ============================================================
//  一、为什么不用 WiFi 名判「在不在家」
//
//  真机诊断页实测 `wifi="nil"`：TrollStore 装的 App 拿不到读 SSID 的
//  entitlement，NEHotspotNetwork 和 CNCopyCurrentNetworkInfo 都返回 nil。
//  拿它当主判据 → 主判据永远是 nil → 每次都掉进兜底分支 → 结果乱七八糟。
//
//  所以：**WiFi 名这条路是死的，不能当主判据。**
//
//  ============================================================
//  二、为什么只探用户配置的那一个地址
//
//  实测 .88 和 .250 是同一台设备的两个 IP，扫到哪个都可能；更糟的是
//  扫完把结果写回用户配置，把用户填的 .88 覆盖成 .250。
//
//  所以：**只探用户配置的那一个地址，不扫网段、不改配置。**
//
//  ============================================================
//  三、为什么必须看 service 字段，不能只看 HTTP 200
//
//  家里网段上可能有别的东西占着 8080（实测网关 .1 就回了 no_cmd_match
//  的 200），只要回 200 就当真会误判。
//
//  ============================================================
//  四、为什么必须判准（差 35 倍）
//
//  内网 192.168.x.x:8080 = 0.07 秒
//  域名 your-name.dpdns.org = 2.5 秒
//  在家里走域名就是白白慢 35 倍。
//
//  ============================================================
//  五、WiFi / 蜂窝 怎么判（2026-11-18 用户要求补的）
//
//  用 `NWPath.usesInterfaceType`：`.wifi` / `.cellular` / `.wiredEthernet`。
//  这是**接口类型**，不是网络名 —— 不需要任何 entitlement，TrollStore
//  装的包照样能拿到。第一条说的「SSID 读数恒为 nil」跟这个无关。
//
//  所以「现在用的是 WiFi 还是数据」判得死准。
//
//  但「这个 WiFi 是不是别人家的」**不可能靠名字判**（SSID 拿不到）。
//  这里用可达性反推，并且在文案里说实话：
//    · 家里 relay 探通            → 自己家（内网直连）
//    · WiFi + 探不通              → 不是自己家的网（别人家 / 公共 WiFi），
//                                   或者自己家但中转站挂了 —— 两种都只能走域名
//    · WiFi + 端口有响应但 service 不对 → 这网上 8080 是别的东西（见第三条）
//    · 蜂窝 + 探不通              → 蜂窝数据
//  判的是「能不能直连」，不是「朋友圈定位」，措辞上不吹牛。
//  ============================================================

import Foundation
import Network
import Darwin

// MARK: - 网络接口类型

/// 现在走的是哪条物理网络。只回答「WiFi / 蜂窝 / 有线」，
/// 不回答「这是谁家的 WiFi」（SSID 读不到，见文件头第五条）。
enum RelayNetwork: String {
    case wifi
    case cellular
    case wired
    /// 明确断网（飞行模式 / 无信号）
    case offline
    /// NWPathMonitor 还没给第一次回调 —— 不知道，别拿它当断网
    case unknown
    /// 有网，但不是上面三种（VPN 之外的其它接口）
    case other

    /// 从 NWPath 读，不做任何猜测。
    static func from(path: NWPath) -> RelayNetwork {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }

    var label: String {
        switch self {
        case .wifi:     return "WiFi"
        case .cellular: return "蜂窝数据"
        case .wired:    return "有线网络"
        case .offline:  return "未联网"
        case .unknown:  return "判定中"
        case .other:    return "其它网络"
        }
    }
}

/// 「家里直连地址通不通」的三种结果。
///
/// 分三种而不是 Bool：`wrongService` 说明**这个网段上有东西占着 8080
/// 但不是家里 relay**（文件头第三条），它和「完全连不上」是两件事，
/// 文案也不该一样 —— 前者说明连到了别的内网，后者说明压根不在那个网段。
enum RelayProbeOutcome: String {
    case reachable
    case wrongService
    case unreachable

    var isReachable: Bool { self == .reachable }
}

// MARK: - 本地网段

/// 手机自己当前的 IPv4 网段。
///
/// 为什么需要它：WiFi 上探不通家里 relay 时分不清两种情况 ——
/// 是「别人家 WiFi」，还是「自己家 WiFi 但中转站挂了」。
/// 前者该说「别人家 WiFi」，后者该说「家里网段但不通」，冤枉哪一个都不好。
///
/// 拿不到 SSID（见文件头第一条），但**本地 IP 拿得到** —— `getifaddrs`
/// 不需要任何 entitlement。en0 在 iPhone 上就是 WiFi。比前三段（/24）
/// 就够了：家用网段极少有人配成 /16 以外的东西。
///
/// 注意这只是「网段相同」，不是「这是我家」—— 别人家也可能用
/// 192.168.1.x。所以文案只说「家里网段」，不断言在家。
enum RelayLocalAddress {

    /// WiFi(en0) 的 IPv4 前三段，例如 "192.168.1"；读不到返回 nil。
    static func wifiSubnetPrefix() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, head != nil else { return nil }
        defer { freeifaddrs(head) }

        var cursor = head
        while let pointer = cursor {
            let entry = pointer.pointee
            defer { cursor = entry.ifa_next }

            guard let addr = entry.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  String(cString: entry.ifa_name) == "en0"
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(addr,
                                socklen_t(addr.pointee.sa_len),
                                &host,
                                socklen_t(host.count),
                                nil, 0,
                                NI_NUMERICHOST)
            guard rc == 0 else { continue }

            let octets = String(cString: host).split(separator: ".")
            guard octets.count == 4 else { continue }
            return octets.prefix(3).joined(separator: ".")
        }
        return nil
    }

    /// 家里地址的网段前缀。只处理 IPv4 字面量（家里地址就是 192.168.x.x）；
    /// 填的是域名 / IPv6 就返回 nil —— 那种情况无法用网段比较。
    static func subnetPrefix(ofIPv4 host: String) -> String? {
        let cleaned = RelayVault.cleanHost(host)
        let octets = cleaned.split(separator: ".")
        guard octets.count == 4,
              octets.allSatisfy({ Int($0) != nil })
        else { return nil }
        return octets.prefix(3).joined(separator: ".")
    }
}

// MARK: - 网络类型快照

/// 当前网络类型的共享快照，线程安全。
///
/// 为什么要有它：`RelayStore` 的 NWPathMonitor 在主队列回调，而
/// `RelayProbe.resolve()` 在后台线程跑（它要 await 网络请求）。
/// 判定读这一个盒子，就不会出现「界面说 WiFi、判定按蜂窝算」。
final class RelayNetworkReading {

    static let shared = RelayNetworkReading()
    private init() {}

    private let lock = NSLock()
    private var stored: RelayNetwork = .unknown

    var value: RelayNetwork {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: RelayNetwork) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

// MARK: - 线路

/// 一条线路。中转站与路由器两个界面共用同一个判定结果，
/// 不会出现「中转站认为在家、路由器认为在外」。
struct RelayRoute: Equatable {

    enum Kind: String {
        case lan
        case wan
    }

    var kind: Kind
    /// 纯 host，**不含协议与端口**。协议和端口由这里按线路决定。
    var host: String
    /// 这次判定时手机上走的是哪条物理网络。
    var network: RelayNetwork = .unknown
    /// 家里直连地址的探测结果。走外网时它解释了「为什么没走直连」。
    var probe: RelayProbeOutcome = .unreachable
    /// WiFi 下当前网段是否与家里地址同网段（/24）。
    /// nil = 判不了（不是 WiFi / 家里填的是域名 / 读不到本地 IP）。
    var sameSubnetAsHome: Bool? = nil

    var isLan: Bool { kind == .lan }

    /// 一句话说清「WiFi 还是数据 + 直连还是外网」。
    /// 用户 2026-11-18 要求的就是这一句。
    var stateText: String {
        switch (kind, network) {
        case (.lan, .wifi):      return "内网直连 · WiFi"
        case (.lan, .cellular):  return "内网直连 · 蜂窝数据"
        case (.lan, .wired):     return "内网直连 · 有线"
        case (.lan, .offline):   return "内网直连"
        case (.lan, _):          return "内网直连"

        case (.wan, .offline):   return "未联网"
        case (.wan, .wifi):
            // WiFi 上但直连不通，分两种，措辞都不撒谎：
            //   · 网段和家里一样 → 大概率在家，但中转站没起来
            //   · 网段不一样     → 别人家 / 公共 WiFi
            // 网段判不出来（家里填的是域名）时只能说「不是家里网络」。
            if sameSubnetAsHome == true { return "外网 · 家里网段" }
            if probe == .wrongService { return "外网 · 这个 WiFi 不是家里网络" }
            return "外网 · 别人家 WiFi"
        case (.wan, .cellular):  return "外网 · 蜂窝数据"
        case (.wan, .wired):     return "外网 · 有线"
        case (.wan, _):          return "外网"
        }
    }

    /// 判定依据，给排查用（自检页 / 路由器页）。
    var probeText: String {
        if network == .offline { return "手机没网，跳过探测" }
        switch probe {
        case .reachable:    return "家里中转站可达（\(host)）"
        case .wrongService: return "8080 有响应，但不是中转站"
        case .unreachable:
            if sameSubnetAsHome == true {
                return "和家里同网段，但中转站没响应"
            }
            return "家里中转站不可达"
        }
    }

    /// 中转站后台（relay.py 网页 + /admin/api/*）
    /// 内网固定 8080（relay 监听端口），域名走 443 由 Cloudflare 隧道转进去。
    var adminBase: String {
        kind == .lan ? "http://\(host):8080" : "https://\(host)"
    }

    /// 路由器指令（uhttpd 的 /cgi-bin/airboot）
    /// 内网 80，域名 443 —— 实测两台服务在同一台设备、同一个 443。
    var bootBase: String {
        kind == .lan ? "http://\(host)" : "https://\(host)"
    }

    /// 给人看的一行。只报「内网 / 外网」，不带「在家 / 在外」这种
    /// 位置暗示 —— 用户要求线路状态只说清走的是哪条线。
    var label: String {
        kind == .lan ? "内网" : "外网"
    }

    /// 路由器的实际访问地址（带端口，给界面看）。
    ///
    /// 不能用 `displayAddress` —— 那个是**后台**地址（内网 8080）。
    /// 路由器指令走的是 uhttpd：内网 80、域名 443。
    /// 把 8080 摆在路由器页上，用户照着敲浏览器是打不开的。
    var routerDisplayAddress: String {
        kind == .lan ? "\(host):80" : host
    }

    var icon: String {
        kind == .lan ? "house.fill" : "globe.asia.australia.fill"
    }

    /// 当前实际在用的地址（带端口），给界面显示用
    var displayAddress: String {
        kind == .lan ? "\(host):8080" : host
    }
}

// MARK: - 判定

enum RelayProbe {

    /// 第一轮判定超时。内网正常 70ms，1.2 秒已经很宽松。
    static let timeout: TimeInterval = 1.2

    /// 第二轮兜底超时。只在第一轮**判失败**时补一次。
    ///
    /// 为什么要补：家里 WiFi 抖动 / 路由器负载高（实测那台 MT7621 只有
    /// 116 MB 内存，采集时可用仅 6 MB）时，`/health` 偶尔真的会慢过 1.2 秒。
    /// 漏判一次的代价不是「慢一点」，而是**整轮请求走域名白慢 35 倍**
    /// （实测内网 0.07s vs 域名 2.5s）。多花 2.5 秒换掉这个漏判，划算。
    static let timeoutRetry: TimeInterval = 2.5

    /// **唯一入口**：现在该走哪条线。
    ///
    /// 只探用户配置的家里地址，一个请求，不扫网段、不改配置。
    ///
    /// 两段式：先 1.2 秒试一次；不通再给 2.5 秒试一次。
    /// 第一次就通的话不会有任何额外延迟。
    ///
    /// 明确断网时直接返回，不打请求 —— 打也是白等 3.7 秒。
    static func resolve() async -> RelayRoute {
        let home = RelayVault.shared.homeHost
        let away = RelayVault.shared.awayHost
        let network = RelayNetworkReading.shared.value

        if network == .offline {
            RelayLog.log("判定：\(network.label)，跳过探测")
            return RelayRoute(kind: .wan, host: away, network: network, probe: .unreachable)
        }

        // WiFi 下才算网段：蜂窝/有线拿 en0 没有意义。
        let sameSubnet: Bool? = {
            guard network == .wifi else { return nil }
            guard let local = RelayLocalAddress.wifiSubnetPrefix(),
                  let homePrefix = RelayLocalAddress.subnetPrefix(ofIPv4: home)
            else { return nil }
            return local == homePrefix
        }()

        var outcome = await probe(home: home, timeout: timeout)
        if outcome != .reachable {
            RelayLog.log("判定：第一轮 \(timeout)s 没通（\(outcome.rawValue)），补一次 \(timeoutRetry)s 重试")
            outcome = await probe(home: home, timeout: timeoutRetry)
        }

        let route = RelayRoute(kind: outcome.isReachable ? .lan : .wan,
                               host: outcome.isReachable ? home : away,
                               network: network,
                               probe: outcome,
                               sameSubnetAsHome: sameSubnet)

        let subnetNote = sameSubnet.map { $0 ? " · 同网段" : " · 不同网段" } ?? ""
        RelayLog.log("判定：\(network.label)\(subnetNote) · 探 \(home):8080 → \(outcome.rawValue) → \(route.stateText)")
        return route
    }

    /// 家里直连地址通不通（三态）。
    ///
    /// 判据用 relay 的 `/health`：
    ///   {"status":"ok","service":"ai-relay",...}
    /// 认 `service` 字段而不是「有 HTTP 响应就算通」—— 见文件头第三条。
    /// 有响应但 service 不对，单独返回 `wrongService`，让文案能说实话。
    ///
    /// - Parameter timeout: 本次探测的超时。第一轮 1.2s，兜底轮 2.5s。
    static func probe(home: String,
                      timeout: TimeInterval = RelayProbe.timeout) async -> RelayProbeOutcome {
        let host = RelayVault.cleanHost(home)
        guard !host.isEmpty, let url = URL(string: "http://\(host):8080/health") else {
            return .unreachable
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 0.6
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        // ⚠️ 用 NSMutableURLRequest 而不是 URLRequest 的 Swift 属性 setter：
        //    `req.httpMethod = ...` / `req.timeoutInterval = ...` 在旧系统上是
        //    缺失的 ABI 符号，调用即 dyld: Symbol not found，App 启动就闪退。
        //    ObjC 消息跨 iOS 14–17 稳定，所以走 mutableCopy。
        let m = NSMutableURLRequest(url: url)
        m.timeoutInterval = timeout
        m.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        m.setValue("Minis/\(RelayDeviceInfo.appVersion) CFNetwork/1410.0.3 Darwin/22.6.0",
                   forHTTPHeaderField: "User-Agent")
        m.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, resp) = try? await session.data(for: m as URLRequest),
              let code = (resp as? HTTPURLResponse)?.statusCode,
              (200...299).contains(code)
        else { return .unreachable }

        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let svc = doc["service"] as? String
        else { return .wrongService }

        // "ai-relay" / "relay" 都认
        return svc.lowercased().contains("relay") ? .reachable : .wrongService
    }
}

// MARK: - 本地网络授权

enum RelayLocalNet {
    /// 主动触发 iOS 的「允许访问本地网络」弹窗。
    ///
    /// iOS 14+ 对发往 192.168.x.x 的请求做权限门控。App 从没发起过 Bonjour
    /// 发现时系统**不弹窗**，而是让请求直接失败 —— 表现就是「连着家里
    /// WiFi 也连不上」。所以冷启动最早的时刻主动起一个 NWBrowser，
    /// 逼系统把弹窗弹出来。
    static func requestPermission() {
        let browser = NWBrowser(for: .bonjour(type: "_minis-relay._tcp", domain: nil),
                                using: .tcp)
        browser.start(queue: DispatchQueue(label: "minis.relay.localnet"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { browser.cancel() }
    }
}

// MARK: - 调试日志

/// 判定过程留痕，出问题时用户能自己看到「为什么走了域名」。
final class RelayLog {

    static let shared = RelayLog()
    private init() {}

    private var lines: [String] = []
    private let lock = NSLock()
    private let maxLines = 60

    static func log(_ s: String) {
        shared.append(s)
    }

    private func append(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = f.string(from: Date()) + "  " + s
        lock.lock()
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    var dump: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    var text: String {
        let all = dump
        return all.isEmpty ? "（暂无记录）" : all.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}

// MARK: - 设备信息

enum RelayDeviceInfo {
    /// 只用来拼 UA（中转站前面挂着 Cloudflare，裸 UA 会被 1010 拒掉）
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}

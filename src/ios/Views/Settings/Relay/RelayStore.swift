//
//  RelayStore.swift
//  Minis — 中转站 / 路由器全局状态
//
//  整个功能只有这一份状态：当前线路、设备状态、密码、路由器在线状况。
//  中转站界面与路由器界面共用同一个判定结果，不会出现
//  「中转站认为在家、路由器认为在外」。
//
//  ============================================================
//  判定逻辑（只有一句）：
//    进界面 / 切页面 / 回前台 / 下拉刷新 → 打一次家里直连地址
//    通 → 在家走直连；不通 → 在外走域名
//
//  刻意没有的东西（都是踩过的坑，别再捡回来）：
//    ✗ WiFi 名判定（读不到 SSID，实测 wifi="nil"）
//    ✗ 定时轮询（白耗电，而且每次判定都可能翻线路）
//    ✗ 扫一堆候选地址 + 把探测结果写回用户配置
//    ✗ 判定失败后自动换对面重试（两条来回翻，永远出不来）
//
//  NWPathMonitor 用了一点点，但**只用作「换网了，立刻重判」的信号**，
//  不拿它做线路判定本身（它分不清「同一个 WiFi 换 SSID」，
//  也说明不了家里的中转站通不通）。
//  ============================================================

import Foundation
import Network
import SwiftUI

@MainActor
final class RelayStore: ObservableObject {

    static let shared = RelayStore()

    /// 当前线路。nil = 还没判过（第一帧）
    @Published private(set) var route: RelayRoute?
    @Published private(set) var device: RelayDeviceStatus?
    /// 路由器 airboot 是否在线。nil = 还没探过
    @Published private(set) var routerOnline: Bool?
    /// 正在判定 / 正在拉数据。界面用它显示转圈。
    @Published private(set) var busy = false
    @Published private(set) var errorText = ""
    /// 需要用户输入后台密码
    @Published var needsPassword = false
    /// 还没配过（没存密码）。跟 needsPassword 不是一回事：
    /// 这个用来显示「去设置」，那个用来显示「密码可能不对」。
    @Published var unconfigured = false
    /// 最近一次操作的结果（重启成功/失败）
    @Published var actionResult: (ok: Bool, text: String)?
    /// 密码/路由密钥被改写过就 +1。
    ///
    /// 为什么需要它：`RelayVault` 是普通类，不是 ObservableObject。
    /// 界面里 `RelayVault.shared.password()` 这种读取，SwiftUI 不会当依赖，
    /// 值变了也不会重算 body —— 于是 `RelayAdminView` 的 `updateUIView`
    /// 根本不会被调用，新密码永远装不进 WKWebView 的注入脚本里。
    /// 表现：设置页显示「密码已记住」，回到后台页面还是「需要访问密钥」。
    /// 所有改 Vault 的地方都把这里 +1，界面就会重算。
    @Published private(set) var vaultRevision = 0

    /// 上次判定的时间。切页面时用来避免同一秒内重复判定。
    private var lastJudge = Date.distantPast
    /// 判定进行中的标记，防止并发判定互相覆盖
    private var judging = false
    /// 上一次的线路，用于判断「判定结果变了」要不要通知界面重载
    private(set) var previousKind: RelayRoute.Kind?

    private init() {
        // 只判断「配没配过」，不判断「需不需要输密码」。
        // 没配过是引导去设置页，不是弹输入框。
        syncUnconfigured()
    }

    /// 「完全没配过密钥」的判定。
    ///
    /// 不能只看后台密码：重启路由器走 airboot，用的是**路由器指令密钥**，
    /// 而 `effectiveRouterKey` 在路由密钥为空时会回落到后台密码。
    /// 所以只要两者任一有值，就不该摆「先填一次密码」的引导卡 ——
    /// 否则用户明明填过路由密钥，进页面还被要求再填一遍。
    private func syncUnconfigured() {
        // 注意：这里判的**只是密钥**，不含中转站档案。
        // 只配了中转站档案、却一个密钥都没填的用户，进后台仍然要密码，
        // 所以对他们必须继续显示引导卡 —— 这两个判定不能合并。
        unconfigured = RelayVault.shared.effectiveRouterKey.isEmpty
            && !RelayVault.shared.hasPassword
    }

    /// 「这台机器上有没有任何跟中转站/路由器相关的东西」。
    ///
    /// 只用于决定**冷启动要不要判定线路**。以前 `MinisApp` 里写的是
    /// `!RelayProfileStore.shared.allProfiles().isEmpty` —— 只配了
    /// **路由器后台**（没配中转站档案）的用户条件为假，于是不 bootstrap：
    /// 进路由器页要等 onAppear 自己判，首帧是空的，看起来像没数据。
    ///
    /// 与 `unconfigured` 的区别：那个问「要不要提示去填密钥」，
    /// 这个问「有没有必要提前探一次网络」。两者判据不同，故意分开。
    var hasAnyConfig: Bool {
        !RelayVault.shared.effectiveRouterKey.isEmpty
            || RelayVault.shared.hasPassword
            || !RelayProfileStore.shared.allProfiles().isEmpty
    }

    /// 冷启动时调一次：触发本地网络授权弹窗 + 首帧就有线路。
    /// 不在 init 里做，避免 App 启动阶段就去打网络。
    func bootstrap() {
        RelayLocalNet.requestPermission()
        startPathWatch()
        Task { await refresh() }
    }

    // MARK: - 网络通路监听

    private let pathMonitor = NWPathMonitor()
    private var pathStarted = false
    private var lastPathKey = ""

    /// 网络通路变化（Wi‑Fi ↔ 蜂窝、断网恢复）时立刻重判。
    ///
    /// 为什么需要：`refreshIfStale()` 只在「进页面 / 回前台」触发。
    /// 用户一直停在前台、中途换了网络 —— 走出家门 Wi‑Fi 掉、蜂窝起来 ——
    /// 页面上的线路还是旧的：明明已经在外，界面仍写「在家 · 直连」，
    /// 点重启会打一个已经不可达的内网地址，看着像按钮坏了。
    private func startPathWatch() {
        guard !pathStarted else { return }
        pathStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let key = "\(path.status == .satisfied)/"
                + "\(path.usesInterfaceType(.wifi))/"
                + "\(path.usesInterfaceType(.cellular))"
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 首个回调只是当前初始状态，不触发重判 —— 否则冷启动
                // 会连着判两次，多打一次 /health。
                if self.lastPathKey.isEmpty {
                    self.lastPathKey = key
                    return
                }
                guard key != self.lastPathKey else { return }
                self.lastPathKey = key
                RelayLog.log("网络通路变化 → \(key)，重判线路")
                // 清掉 1 秒的 staleness 门限：这是真换网了，必须立刻重判。
                self.lastJudge = .distantPast
                Task { await self.refresh() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "minis.relay.path"))
    }

    // MARK: - 判定 + 拉数据

    /// 判定线路 + 拉设备状态。**唯一的刷新入口**。
    /// 下拉刷新、切页面、回前台都调它。
    func refresh() async {
        guard !judging else { return }
        judging = true
        busy = true
        errorText = ""
        defer { judging = false; busy = false }

        let r = await RelayProbe.resolve()
        let changed = (route?.kind != r.kind) || (route?.host != r.host)
        route = r
        lastJudge = Date()

        if changed, let p = previousKind {
            RelayLog.log("线路变化 \(p.rawValue) → \(r.kind.rawValue)，界面需要重载")
        }
        previousKind = r.kind

        let key = RelayVault.shared.password() ?? ""
        if key.isEmpty {
            // 没存过后台密码 ≠ 什么都不知道。
            // airboot 的 ping **不需要任何密钥**（实测直接回 svc:airboot），
            // 所以路由器在不在线照样能探出来 —— 这对「能不能重启路由器」
            // 是关键信息，不能因为没后台密码就连这个也跳过。
            needsPassword = false
            syncUnconfigured()
            device = nil
            routerOnline = await RelayRouter.ping(route: r)
            syncProviders(isLan: r.isLan)
            return
        }
        // 能走到这里说明后台密码有值 —— 那必然不算「从未配置」。
        // 仍然走 syncUnconfigured() 保持判定只有一处定义，
        // 也顺带覆盖「路由密钥被清空但后台密码还在」这种情况。
        syncUnconfigured()

        async let devResult = RelayBackend.fetchDevice(base: r.adminBase, key: key)
        async let online = RelayRouter.ping(route: r)

        let result = await devResult
        routerOnline = await online

        switch result {
        case .success(let d):
            device = d
            errorText = ""
            needsPassword = false
        case .failure(let e):
            device = nil
            if e.isBadKey {
                // 401/403 才说明密码真的不对。
                // 但先别急 —— 可能是后端重启后会话态丢了，
                // 用同一个密码在另一条线路上再试一次，能通就不打扰用户。
                if let retried = await retryOnOtherRoute(key: key, from: r) {
                    device = retried
                    errorText = ""
                    needsPassword = false
                } else {
                    // 两条线路都明确 401/403 —— 密码是真的不对了。
                    //
                    // 必须把话说出来：以前这里只置了 needsPassword，
                    // 而没有任何界面读它，于是用户看到的是「设备状态一片 —」，
                    // 进后台也只看到一句「需要访问密钥」，根本猜不到是密码问题。
                    needsPassword = true
                    errorText = "后台密码现在不对了。可能路由器那边改过 —— 去「地址与密码设置」重新填一次。"
                }
            } else {
                // 连不上 ≠ 密码错。别让用户重输一个本来正确的密码。
                needsPassword = false
                errorText = r.isLan
                    ? "在家直连 \(r.displayAddress) 没响应。中转站可能卡住了，可以试「只重启中转站」。"
                    : "走域名连不上 \(r.host)。检查隧道，或者你现在其实在家里（拉一下刷新重判）。"
            }
        }

        // 把本次判定结果同步给「AI 中转站」服务商档案，
        // 这样发消息时 requestBaseURL 拿到的是当前网络上通的地址。
        syncProviders(isLan: r.isLan)
    }

    /// 一条线路返回 401 时，用**同一个已保存的密码**在另一条线路上再试一次。
    ///
    /// 目的：避免把「后端重启 / 走错线路 / 隧道抖动」误判成「密码错了」。
    /// 只要另一条能通，就当密码是对的，压根不打扰用户。
    /// 只有两条线路都明确 401/403，才认为密码真的变了。
    private func retryOnOtherRoute(key: String, from r: RelayRoute) async -> RelayDeviceStatus? {
        let otherHost = r.isLan ? RelayVault.shared.awayHost : RelayVault.shared.homeHost
        guard !otherHost.isEmpty, otherHost != r.host else { return nil }
        let other = RelayRoute(kind: r.isLan ? .wan : .lan, host: otherHost)
        guard case .success(let d) = await RelayBackend.fetchDevice(base: other.adminBase,
                                                                   key: key) else { return nil }
        RelayLog.log("\(r.kind.rawValue) 判密码错，但 \(other.kind.rawValue) 通了 —— 判定为线路问题，不打扰用户")
        return d
    }

    /// 判定结果 → 中转站服务商档案。
    /// 只更新「自动判定」模式的档案；用户显式选了「只用内网 / 只用外网」
    /// 就尊重他的选择，不去覆盖。
    private func syncProviders(isLan: Bool) {
        let profiles = RelayProfileStore.shared.allProfiles()
        for p in profiles where p.routeMode == .auto {
            RelayProfileStore.shared.updateResolution(instanceId: p.instanceId, isLan: isLan)
        }
    }

    /// 下拉刷新 / 切页面 / 回前台调这个。
    ///
    /// 加 1 秒去抖：切页面瞬间会连续触发几次，没必要每次都探一遍。
    /// 但下拉刷新（用户主动）不受限，走 refresh() 本体。
    func refreshIfStale() {
        guard !judging else { return }
        guard Date().timeIntervalSince(lastJudge) > 1.0 else { return }
        Task { await refresh() }
    }

    /// App 回到前台
    func becameActive() {
        refreshIfStale()
    }

    // MARK: - 密码

    /// 密码只有一个写入口：`changePassword`。
    /// 以前这里还有一个 `submitPassword(_:)`，它自己又实现了一遍「两条线路
    /// 都试一次」的验证逻辑，和设置页的 `verify()` 是同一件事的两份代码。
    /// 两份迟早分叉，已经删掉 —— 输密码的界面只有一个（设置页），
    /// 里面 verify 通了才调 `changePassword`。

    func changePassword(_ raw: String) {
        RelayVault.shared.save(password: raw)
        // 刚存好 = 一定不需要再问；是否「从未配置」交给唯一判定。
        // 这里尤其不能写 unconfigured = !hasPassword ——
        // 用户只配了路由器指令密钥、把后台密码清空时，重启路由器照样能做，
        // 写死会把引导卡重新摆出来，等于又逼他填一遍。
        needsPassword = false
        syncUnconfigured()
        vaultRevision += 1
    }

    /// 存路由器指令密钥。界面也要跟着重算（按钮小字、引导卡）。
    func changeRouterKey(_ raw: String) {
        RelayVault.shared.saveRouterKey(raw)
        syncUnconfigured()
        vaultRevision += 1
    }

    /// 存路由器型号。只影响路由器页那行展示，但不 +1 的话
    /// 那个页面读 `RelayVault.shared.routerModel` 建立不起依赖，
    /// 用户改完回来还是旧值 —— 和密码那边是同一个坑。
    func changeRouterModel(_ raw: String) {
        RelayVault.shared.routerModel = raw
        vaultRevision += 1
    }

    // MARK: - 操作

    enum PowerAction {
        case restartRelay
        case rebootRouter

        var confirmTitle: String {
            self == .restartRelay ? "只重启中转站？" : "重启整个路由器？"
        }
        var confirmMessage: String {
            self == .restartRelay
                ? "中转站进程会重启，网页断几秒就恢复。路由器本身不动，WiFi 不断。"
                : "整台路由器重启，家里所有设备会断网约 1 分钟。"
        }
        var confirmButton: String {
            self == .restartRelay ? "重启中转站" : "重启路由器"
        }
        var successText: String {
            self == .restartRelay
                ? "中转站已重启。等几秒拉一下刷新就行。"
                : "路由器已重启。约 1 分钟后恢复。"
        }
    }

    /// 能不能做这个操作。
    ///
    /// 重启路由器有两条独立路径，**在外也能重启**：
    ///   · 在家 → 走 airboot（快，且能立刻生效）
    ///   · 在外 → 走后台 /admin/api/device/reboot（经 Cloudflare 隧道）
    ///
    /// 注意：这里**不**拿 device / routerOnline 当前置条件。
    /// 那两个值只是「上一次刷新拿到的快照」，在外时 airboot 本来就探不到
    /// （80 端口不出公网），后台接口在没输密码时也拿不到 device ——
    /// 用它们判断会把按钮变灰，用户看着是「外就不能重启」，其实是设计错。
    /// 只要有线路就允许点，缺密码/连不上由 perform 的错误文案说明。
    func canPerform(_ action: PowerAction) -> Bool {
        guard route != nil else { return false }
        switch action {
        case .restartRelay:
            return true
        case .rebootRouter:
            // 在家、在外都可行；两条路都不通时才由 perform 报错。
            return true
        }
    }

    func perform(_ action: PowerAction) async {
        guard let r = route else { return }
        actionResult = nil

        // 重启路由器有三条可用路径，按「门槛从低到高」排：
        //  ① 在家 → airboot（http 80）—— 只要路由器指令密钥
        //  ② 在外 → airboot（https 443，Cloudflare 隧道会把同一个
        //     /cgi-bin/airboot 转进去）—— 实测 2026-11-09 直接回
        //     {"ok":true,"svc":"airboot"}，**只要路由器指令密钥，不需要后台密码**
        //  ③ 通道全挂 → 后台 /admin/api/device/reboot —— 需要后台密码
        //
        // 所以「没有后台密码」**不能**当成拒绝理由。以前这里在外 + 没密码
        // 就直接 return，等于把用户锁在门外；而实际上 ② 就能干成。
        do {
            switch action {
            case .restartRelay:
                // 只重启中转站：airboot 的 relay 动作，WiFi 不断
                try await RelayRouter.restartRelay(route: r,
                                                   key: RelayVault.shared.effectiveRouterKey)
            case .rebootRouter:
                try await rebootRouterWithFallback(r)
            }
            actionResult = (true, action.successText)
        } catch {
            let msg = (error as? RelayError)?.errorDescription ?? error.localizedDescription
            actionResult = (false, msg)
            // 因为「没密钥」而失败时，把引导卡摆出来 —— 否则用户看到
            // 一句「还没填密钥」却找不到填的地方。判定仍走唯一入口。
            if let e = error as? RelayError, case .noKey = e {
                syncUnconfigured()
            }
        }
    }

    /// 重启路由器：airboot 优先（两条线路都走它），失败才退到后台接口。
    ///
    /// 顺序写死在这里，界面不需要知道区别。
    private func rebootRouterWithFallback(_ r: RelayRoute) async throws {
        let routerKey = RelayVault.shared.effectiveRouterKey
        var airbootError: Error?

        if !routerKey.isEmpty {
            do {
                try await RelayRouter.reboot(route: r, key: routerKey)
                return
            } catch {
                airbootError = error
                RelayLog.log("airboot 重启失败（\(r.kind.rawValue)）：\(error.localizedDescription)，改用后台接口")
            }
        }

        // 退路：后台接口。要有后台密码。
        let adminKey = RelayVault.shared.password() ?? ""
        if adminKey.isEmpty {
            // 两条路都缺凭据：说清楚缺的是哪一样，而不是笼统「失败了」。
            if routerKey.isEmpty {
                throw RelayError.noKey
            }
            // 有路由密钥但 airboot 打不通、又没有后台密码 —— 把 airboot 的错抛出去
            throw airbootError ?? RelayError.offline
        }

        try await RelayBackend.rebootRouter(base: r.adminBase, key: adminKey)
    }

    func clearActionResult() { actionResult = nil }
}

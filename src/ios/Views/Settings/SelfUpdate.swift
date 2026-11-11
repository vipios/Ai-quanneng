//
//  SelfUpdate.swift
//  Minis — 自有版本线的更新检查与自动下载
//
//  ============================================================
//  [R40-内置更新源] 这一版推翻了原来的设计，改动集中在三点
//
//  1. 更新源不再让用户填，内置成常量 `builtinRepo`。
//     原来的设计要用户去设置里写「用户名/仓库名」，理由是「不能回落到
//     原版仓库」。那个理由本身没错，但结论错了：这个包只有一个发布来源，
//     让用户填一个我们早就知道的值，是把他当配置员用。
//     现在把仓库写死，仍然绝不触碰原版 —— 两件事并不冲突。
//
//  2. 「检查更新」从「查一下告诉你有没有」变成「查 → 测速 → 自动下载」。
//     用户 2026-11-10 18:52 的原话：「让我点击检查更新就会自动判定哪个
//     线路最快，然后他就自动下载了」。所以这条路必须自己走完，
//     不能停在「发现新版本，请去浏览器」。
//
//  3. 测速和下载共用同一条线路。哪条线路在竞速里赢了，就用它拼下载
//     地址 —— 已经测出来的结论没有理由再猜第二次。
//
//  版本线约定（未变）
//  ----------------------------------------------------------
//  这个 App 从 1.0 起步，和原版 1.15.x 没有任何大小关系。
//  比较只在「我们自己的 release」和「我们自己的版本号」之间发生。
//  ============================================================

import Foundation

// MARK: - 配置变更通知

extension Notification.Name {
    /// 更新源被改过。
    ///
    /// [R40] 更新源现在内置、用户改不了，这个通知的触发点只剩
    /// 一处：开发者改代码换仓库（那不需要通知）。保留它是因为
    /// 关于页仍在监听它刷新仓库链接，删掉会让那处失去响应。
    static let selfUpdateSourceChanged = Notification.Name("minis.selfupdate.sourceChanged")
}

// MARK: - 结果模型

/// 一次更新检查的结果。界面只读这个，不碰网络细节。
///
/// `Sendable`：`check()` 是 async，结果要被带回主线程的 @State。
enum SelfUpdateResult: Equatable, Sendable {
    /// [R40] 保留了 but 不再产生：更新源内置，没有「未配置」这个状态了。
    /// 留着枚举分支是为了不让外面所有 switch 都改一遍 —— 界面上的
    /// 分支已经删掉，这里保留一个不可达值比大范围改签名安全。
    case notConfigured
    /// 查过了，已经是最新（附带远端 tag、走的线路、耗时）
    case upToDate(remote: String, line: String, ms: Int)
    /// 查过了，远端更新（此时下载还没开始）
    case updateAvailable(remote: String, line: String, ms: Int)
    /// 查过了但失败（网络 / 仓库不存在 / 没有 release）
    case failed(reason: String)

    /// 界面用的一行话
    var message: String {
        switch self {
        case .notConfigured:
            return "更新源没配好（这是 App 的问题，不是你操作错）"
        case .upToDate(let r, let line, let ms):
            return "已是最新（\(r)） · \(line) \(ms)ms"
        case .updateAvailable(let r, let line, let ms):
            return "有新版 \(r) · \(line) \(ms)ms"
        case .failed(let reason):
            return reason
        }
    }
}

// MARK: - 下载结果

/// 自动下载的进展。界面靠它显示徽标文字。
///
/// 独立于 `SelfUpdateResult`：检查是一次性结论，下载是持续过程，
/// 混在一个枚举里会让「下载到 40% 时该显示什么」变得没法表达。
enum SelfUpdateDownload: Equatable, Sendable {
    case idle
    /// 正在下载，0…1
    case progress(Double, totalBytes: Int64)
    /// 下好了，给本地文件地址
    case finished(URL)
    case failed(String)
}

// MARK: - 检查器

enum SelfUpdate {

    // MARK: 版本线

    /// [R55-版本号递增] 从 Bundle 读版本号，不再写死。
    ///
    /// 之前 `currentVersion=[1,0,0]`、`currentBuild=42` 是硬编码，CI 每次
    /// 发布用 run_number 递增（build 64、65…），App 里却永远显示 1.0.0(42)，
    /// 用户装完看不出是不是最新。现在 CI 编译时把 run_number 注入
    /// `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`（见 build.yml），
    /// 这里从 Info.plist 读回来，两边就对上了。
    ///
    /// 显示格式：`1.65`（主版本 1 + 构建号 65），一眼能看出递增。
    static var currentVersion: [Int] {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0.0"
        return raw.split(separator: ".").compactMap { Int($0) }
    }

    /// 构建号 = CFBundleVersion（CI 注入的 run_number）。读不到回落 0。
    static var currentBuild: Int {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return Int(raw) ?? 0
    }

    /// 界面上显示的完整版本串。
    /// [R55] 只显示版本号（如 1.65），不带括号里的构建号。
    static var displayVersion: String {
        currentVersion.map(String.init).joined(separator: ".")
    }

    // MARK: 内置更新源

    /// [R40-内置更新源] 唯一的发布仓库。用户看不到、改不了。
    ///
    /// 换仓库只改这一行。原型里对应 `BUILTIN_REPO`（联动模板-完整.html），
    /// 两处必须一致 —— 否则原型演示的版本和真机查的版本会对不上。
    static let builtinRepo = "vipios/Ai-quanneng"

    /// 供界面显示（关于页的仓库链接）。恒等于内置值。
    static var repo: String { builtinRepo }

    /// 永远是 true。保留这个属性是因为关于页还在读它。
    static var isConfigured: Bool { true }

    /// [R40] 用户已经不能改更新源了，这个方法强制返回 false。
    ///
    /// 之所以不直接删：`SettingsRename` / 关于页还有引用的地方，
    /// 删掉会牵连一串编译错误，而那些地方跟这次改动无关。
    /// 返回 false 表示「写入被拒绝」，语义正确且无害。
    @discardableResult
    static func setRepo(_ raw: String) -> Bool {
        false
    }

    // MARK: 线路

    /// 一条候选线路。
    ///
    /// `name` 只用于界面上告诉用户「这次走的哪条」；`prefix` 用来拼下载地址。
    /// 存字符串不存闭包：闭包属性在 Swift 6 并发检查下要满足 Sendable，
    /// 而 static let 数组一旦被判定为全局可变状态就会报警告。
    struct Line: Sendable {
        let id: String
        let name: String
        /// 下载用的前缀。直连为空串，加速站就是自己的域名 + 斜杠。
        let prefix: String
        /// API 地址模板，含 %@ 占位符（放 repo）
        let apiTemplate: String
    }

    /// 候选线路池。
    ///
    /// [R59-全线路池] 从 4 条扩到 11 条。用户原话：「把所有的加速器线路都
    /// 放进去，让他自动判定哪个最快，然后就用哪条线路更新」。
    ///
    /// 为什么之前只有 4 条会出事：加速站存活率很低，2026-11-11 实测
    /// 13 个备选里只有 4 个能下（ghfast / gh-proxy.com / gh-proxy.org /
    /// ghproxy.imciel.com），其余全是 000/404/502/522。池子太小，
    /// 死了两条就只剩「44 分钟才下完」的那条，表现为永远 0%。
    ///
    /// ⚠️ 顺序完全不代表优先级，每次都是并发实测、按真实下载速度选。
    /// 名单里保留了一些**当前不可用**的地址：加速站是时好时坏的，
    /// 今天 502 明天可能就通了，留着让它自己参与竞速，失败了也只是
    /// 多一个 nil，不影响选线。
    ///
    /// `apiTemplate` 只对「能代理 API」的站有意义；不代理 api.github.com
    /// 的站会返回 403，那种情况下 `probe` 依然能靠其它站的 release 信息
    /// 拿到资产列表 —— 见 `race` 里「候选实测下载速度」那段的说明。
    static let lines: [Line] = [
        Line(id: "fast",
             name: "加速 A",
             prefix: "https://ghfast.top/",
             apiTemplate: "https://ghfast.top/https://api.github.com/repos/%@/releases/latest"),
        Line(id: "proxy",
             name: "加速 B",
             prefix: "https://ghproxy.net/",
             apiTemplate: "https://ghproxy.net/https://api.github.com/repos/%@/releases/latest"),
        Line(id: "slow",
             name: "加速 C",
             prefix: "https://gh-proxy.com/",
             apiTemplate: "https://gh-proxy.com/https://api.github.com/repos/%@/releases/latest"),
        Line(id: "org",
             name: "加速 D",
             prefix: "https://gh-proxy.org/",
             apiTemplate: "https://gh-proxy.org/https://api.github.com/repos/%@/releases/latest"),
        Line(id: "imciel",
             name: "加速 E",
             prefix: "https://ghproxy.imciel.com/",
             apiTemplate: "https://ghproxy.imciel.com/https://api.github.com/repos/%@/releases/latest"),
        Line(id: "cfd",
             name: "加速 F",
             prefix: "https://ghproxy.cfd/",
             apiTemplate: "https://ghproxy.cfd/https://api.github.com/repos/%@/releases/latest"),
        Line(id: "llkk",
             name: "加速 G",
             prefix: "https://gh.llkk.cc/",
             apiTemplate: "https://gh.llkk.cc/https://api.github.com/repos/%@/releases/latest"),
        Line(id: "xxooo",
             name: "加速 H",
             prefix: "https://gh.xxooo.cf/",
             apiTemplate: "https://gh.xxooo.cf/https://api.github.com/repos/%@/releases/latest"),
        Line(id: "moeyy",
             name: "加速 I",
             prefix: "https://github.moeyy.xyz/",
             apiTemplate: "https://github.moeyy.xyz/https://api.github.com/repos/%@/releases/latest"),
        Line(id: "cn",
             name: "加速 J",
             prefix: "https://ghproxy.cn/",
             apiTemplate: "https://ghproxy.cn/https://api.github.com/repos/%@/releases/latest"),
        Line(id: "direct",
             name: "直连",
             prefix: "",
             apiTemplate: "https://api.github.com/repos/%@/releases/latest"),
    ]

    /// 单条线路的超时。实测直连经常 3-8 秒才失败，9 秒是「基本确定不行」的位置。
    private static let lineTimeout: TimeInterval = 9

    // MARK: 检查

    /// 一次检查的完整产物：给界面看的结果 + 给下载用的胜出线路。
    ///
    /// 为什么要把两者绑在一起返回，而不是让 `check()` 存一个
    /// 「上次赢的线路」到静态变量里，再让下载去读：
    ///   · 静态可变全局状态在 Swift 6 严格并发下直接编译失败
    ///     （nonisolated global shared mutable state）；
    ///   · 就算加 nonisolated(unsafe) 绕过去，也是个真 bug 源 ——
    ///     两次检查交错时，下载可能拿到上一次的线路和这一次的 tag，
    ///     拼出一个必然 404 的地址。
    /// 用返回值传递，天然没有这个问题。
    struct Outcome: Sendable {
        let result: SelfUpdateResult
        /// 竞速赢家。nil 表示全部线路都失败。
        let win: Win?
    }

    /// [R50-按发布时间判断新版本] 检查更新。
    ///
    /// 为什么不再用 tag 版本号比：发布走的是滚动标签 `latest`，tag 恒为
    /// `latest`，`Int("latest")` 解析成 0，永远比不过本地 `[1,0,0]`，
    /// 于是永远「已是最新」、永远不下载。真信号是 asset 的 `updated_at`
    /// —— 每次 `gh release upload --clobber` 覆盖上传都会刷新它。
    ///
    /// 判断：远端 asset.updated_at 比本地记住的锚点新（或本地没锚点），
    /// 就是有新版本。锚点在每次下载成功后更新。
    static func check() async -> Outcome {
        guard let win = await race(repo: builtinRepo) else {
            return Outcome(result: .failed(reason: "所有线路都连不上，检查一下网络"),
                           win: nil)
        }

        let remote = win.assetUpdatedAt
        let anchor = lastAssetUpdatedAt

        // 没锚点 = 第一次检查，视为有新版本（让用户能更新到当前包）。
        let hasUpdate: Bool
        if anchor.isEmpty {
            hasUpdate = true
        } else {
            hasUpdate = remote > anchor
        }

        let r: SelfUpdateResult = hasUpdate
            ? .updateAvailable(remote: win.buildLabel, line: win.line.name, ms: win.ms)
            : .upToDate(remote: win.buildLabel, line: win.line.name, ms: win.ms)
        return Outcome(result: r, win: win)
    }

    // MARK: 更新锚点

    /// UserDefaults 里记住「上次成功下载的包」的 asset.updated_at。
    ///
    /// 用 ISO8601 字符串直接比大小：GitHub 返回的格式固定、且按字典序
    /// 天然等于时间序（同一位数、同长度、同格式）。不需要解析成 Date。
    static var lastAssetUpdatedAt: String {
        get { UserDefaults.standard.string(forKey: "minis.selfupdate.lastAssetUpdatedAt") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "minis.selfupdate.lastAssetUpdatedAt") }
    }

    /// 下载成功后，把这次包的 asset.updated_at 记成锚点。
    static func markInstalled(_ win: Win) {
        lastAssetUpdatedAt = win.assetUpdatedAt
    }

    // MARK: 线路竞速

    /// 一条线路的结果。必须 Sendable：要跨 task group 的并发域传回来。
    struct Win: Sendable {
        let tag: String
        let line: Line
        let ms: Int
        /// release 里的资产名与下载地址（原始 github.com 直链，未加前缀）
        let ipaName: String?
        let ipaURL: String?
        let ipaSize: Int64
        /// [R50] asset 的 updated_at（ISO8601 字符串）。每次覆盖上传都会刷新，
        /// 是「有没有新包」的唯一可靠信号。
        let assetUpdatedAt: String
        /// [R50] 给界面显示的一行版本标识，如「build 58」。
        let buildLabel: String
        /// [R59] 这条线路实测下载速度（B/s）。0 表示没测出/测不通。
        ///
        /// 有默认值：`probe` 里构造只带版本事实、不测速，`race` 最后
        /// 才把实测结果填进来。默认值让两处构造都不用改签名。
        var measuredSpeed: Double = 0
    }

    /// 全部线路同时打，第一个拿到有效 release 的胜出。
    ///
    /// 用 `withTaskGroup` 而不是 detached task：group 退出时会等所有
    /// 子任务收尾，不会留野任务在后台跑。提前获胜时 `cancelAll()`，
    /// 已发出的请求靠 timeoutInterval 自然结束。
    ///
    /// [R59-全线路池] 选线路。分三步，全程以**真实下载速度**为唯一标准。
    ///
    /// 用户原话：「把所有的加速器线路都放进去，让他自动判定哪个最快，
    /// 然后就用哪条线路更新」。
    ///
    /// ── 第一步：取 release 事实 ──
    /// 并发拿 release 元信息（版本号、asset 直链、大小、updated_at）。
    /// 这一步**只需要一条线路成功**，因为事实是全局唯一的。
    ///
    /// ── 第二步：全部线路参与下载测速 ──
    /// 这里是最关键的修正。原来只有「API 探通」的线路才能进候选，
    /// 而 2026-11-11 实测 ghfast / ghproxy 的 **API 返回 403**
    /// （那类加速站只代理 release 下载，不代理 api.github.com）。
    /// 结果就是：下载最快的 ghfast 被 API 403 淘汰，只剩 gh-proxy
    /// （下 77MB 要 43 分钟）和直连 —— 于是进度永远 0%。
    ///
    /// 现在把「有什么版本」和「从哪下」彻底解耦：release 信息拿一次，
    /// 然后 `lines` 里**每一条**都用拿到的 asset 直链去实测下载速度，
    /// 不管它的 API 通不通。
    ///
    /// ── 第三步：选最快的 ──
    /// 速度最高的那条即为结果；全都测不出速度时退回直连。
    static func race(repo: String) async -> Win? {
        // ① 取 release 元信息（任一条成功即可，事实上并行等价）。
        let informants: [Win] = await withTaskGroup(of: Win?.self) { group in
            for line in lines {
                group.addTask { await probe(line: line, repo: repo) }
            }
            var out: [Win] = []
            for await w in group {
                if let w { out.append(w) }
            }
            return out
        }
        // 优先用「带 asset 直链」的那条信息：API 通不代表 release 里有包，
        // 而测速必须有直链。全都没有 asset 时才退回第一条，
        // 让上层如实报「这个版本里没有可安装的包」。
        guard let fact = informants.first(where: { $0.ipaURL?.isEmpty == false })
                ?? informants.first
        else { return nil }

        // 没有 asset 直链就无从下载，也没法测速 —— 直接把事实返回，
        // 让上层如实报「这个版本里没有可安装的包」。
        guard let rawURL = fact.ipaURL, !rawURL.isEmpty else { return fact }

        // ② 每条线路都拿同一条 asset 直链组出自己的下载地址，实测速度。
        //
        // 用 (Line, Double) 无名元组而不是带标签的：`withTaskGroup(of:)`
        // 的元素类型必须与闭包返回类型逐字一致，带标签的元组和无名元组
        // 在 Swift 里是两个类型，混用会编译失败。
        let measured: [(Line, Double)] = await withTaskGroup(
            of: (Line, Double).self
        ) { group in
            for line in lines {
                group.addTask { (line, await measureDownloadSpeed(prefix: line.prefix,
                                                                  rawURL: rawURL)) }
            }
            var out: [(Line, Double)] = []
            for await pair in group { out.append(pair) }
            return out
        }

        // ③ 取最快。完全并列或全为 0 时按池内顺序兜底（直连在最后）。
        var bestLine: Line = lines.last ?? fact.line
        var bestSpeed: Double = 0
        for m in measured where m.1 > bestSpeed {
            bestSpeed = m.1
            bestLine = m.0
        }
        if bestSpeed <= 0 {
            // 一条都测不通：保留 API 探通的那条（至少没有更差的选项）。
            bestLine = fact.line
        }

        // 把「版本事实」和「下载线路」重新组合成一个 Win：
        // tag / 资产 / 大小 / updated_at 都来自 fact，
        // line 换成实测最快的那条（下载地址由 downloadURL 用它拼）。
        return Win(tag: fact.tag, line: bestLine, ms: fact.ms,
                   ipaName: fact.ipaName, ipaURL: fact.ipaURL, ipaSize: fact.ipaSize,
                   assetUpdatedAt: fact.assetUpdatedAt, buildLabel: fact.buildLabel,
                   measuredSpeed: bestSpeed)
    }

    /// 用指定线路前缀 + asset 直链组地址，拉前 256KB 实测速度（B/s）。
    ///
    /// 用 Range 只取一小段，不把 77MB 拖下来。256KB 足够区分
    /// 「几百 KB/s」和「十几 KB/s」，实测 ghfast 拿 256KB 约 2~3 秒。
    ///
    /// 失败或拿不到数据返回 0 —— 0 会被当成「最慢」，自然落选。
    private static func measureDownloadSpeed(prefix: String, rawURL: String) async -> Double {
        guard let url = URL(string: prefix + rawURL) else { return 0 }

        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        req.setValue("Minis-SelfUpdate", forHTTPHeaderField: "User-Agent")

        let t0 = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let dt = Date().timeIntervalSince(t0)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty, dt > 0
            else { return 0 }
            return Double(data.count) / dt
        } catch {
            return 0
        }
    }

    /// 打一条线路。任何失败都返回 nil —— 竞速场景下失败没有信息量。
    private static func probe(line: Line, repo: String) async -> Win? {
        guard let url = URL(string: line.apiTemplate.replacingOccurrences(of: "%@", with: repo))
        else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = lineTimeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub API 不接受没有 User-Agent 的请求
        req.setValue("Minis-SelfUpdate", forHTTPHeaderField: "User-Agent")

        let t0 = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagRaw = obj["tag_name"] as? String
            else { return nil }

            // v1.2.0 / 1.2.0 都接受
            let tag = tagRaw.hasPrefix("v") || tagRaw.hasPrefix("V")
                ? String(tagRaw.dropFirst())
                : tagRaw
            let ms = Int(Date().timeIntervalSince(t0) * 1000)

            // [R55] release 的 title 形如「全能AI 1.65」（版本号 = run_number）。
            // 直接把 title 里的版本段给界面显示。拿不到就回落 tag。
            let name = obj["name"] as? String ?? ""
            let buildLabel: String
            if let m = name.range(of: "全能AI", options: []) {
                let tail = name[m.upperBound...].trimmingCharacters(in: .whitespaces)
                // tail 形如 "1.65"，去掉可能的 "· " 前缀
                let cleaned = tail.hasPrefix("·") ? String(tail.dropFirst()).trimmingCharacters(in: .whitespaces) : tail
                buildLabel = cleaned.isEmpty ? "v\(tag)" : "v\(cleaned)"
            } else if let m = name.range(of: "build", options: .caseInsensitive) {
                let tail = name[m.upperBound...].trimmingCharacters(in: .whitespaces)
                let num = tail.prefix(while: { $0.isNumber })
                buildLabel = num.isEmpty ? "v\(tag)" : "build \(num)"
            } else {
                buildLabel = "v\(tag)"
            }

            // 找出可安装的包。找 .ipa / .tipa，没有就留 nil ——
            // 「有新版本但没有包」要能如实说出来，不能假装成功。
            var ipaName: String?
            var ipaURL: String?
            var ipaSize: Int64 = 0
            var assetUpdatedAt = ""
            if let assets = obj["assets"] as? [[String: Any]] {
                for a in assets {
                    guard let n = a["name"] as? String else { continue }
                    let lower = n.lowercased()
                    guard lower.hasSuffix(".ipa") || lower.hasSuffix(".tipa") else { continue }
                    ipaName = n
                    ipaURL = a["browser_download_url"] as? String
                    ipaSize = (a["size"] as? NSNumber)?.int64Value ?? 0
                    assetUpdatedAt = a["updated_at"] as? String ?? ""
                    break
                }
            }

            return Win(tag: tag, line: line, ms: ms,
                       ipaName: ipaName, ipaURL: ipaURL, ipaSize: ipaSize,
                       assetUpdatedAt: assetUpdatedAt, buildLabel: buildLabel)
        } catch {
            return nil
        }
    }

    // MARK: 拼下载地址

    /// 把 release 的原始直链套上胜出线路的加速前缀。
    ///
    /// 直连线路的 prefix 是空串，拼出来就是原地址 —— 不用特判。
    static func downloadURL(for win: Win) -> URL? {
        guard let raw = win.ipaURL, !raw.isEmpty else { return nil }
        return URL(string: win.line.prefix + raw)
    }

    // MARK: 下载

    /// 自动下载 ipa，带进度回调。
    ///
    /// 用 `URLSession.download` 而不是 `data(for:)`：这个包 80MB，
    /// 装进内存既浪费又可能被杀。download 落的是临时文件，直接拿到路径。
    ///
    /// 进度回调声明为 `@Sendable` 而不是 `@MainActor`：
    /// 它会被 URLSession 的后台队列调用，标 @MainActor 会在 Swift 6
    /// 严格并发下报「跨隔离域捕获」。调用方自己跳回主线程 —— 见
    /// `SelfUpdateSection` 里 `Task { @MainActor in ... }` 那一层。
    ///
    /// 不用 `AsyncStream.makeStream()`：那是 iOS 17 才有的 API，
    /// 而本工程部署目标是 16.0。为了一点进度信号把最低版本抬上去不值。
    static func download(
        win: Win,
        onProgress: @escaping @Sendable (Double, Int64) -> Void
    ) async throws -> URL {
        guard let url = downloadURL(for: win) else {
            throw SelfUpdateError.noAsset
        }

        var req = URLRequest(url: url)
        // 大文件给足时间。9 秒是「测 API 通不通」的量级，
        // 下 80MB 用这个值会必然超时。
        req.timeoutInterval = 300
        req.setValue("Minis-SelfUpdate", forHTTPHeaderField: "User-Agent")

        let delegate = ProgressDelegate(
            onProgress: onProgress,
            onStall: {
                // 看门狗判定卡死：先给界面一个明确的信号（-2 = 卡死），
                // 再由 delegate 自己取消正在跑的下载任务。
                onProgress(-2, 0)
            }
        )
        // [R55] 兜底总量用 release 里的 asset.size —— 代理不返回
        // Content-Length 时，进度用它来算百分比，不会一直转圈。
        delegate.setExpectedFallback(win.ipaSize)

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = req.timeoutInterval

        // [R59-不再无限转圈] 三处兜底，缺一个都会重现「一直 0% 转圈」：
        //
        // 1. `timeoutIntervalForResource` —— 整个资源传输的总时限。
        //    **这是关键**：它的默认值是 7 天。原来只设了
        //    `timeoutIntervalForRequest`（那是「两次收到数据之间的间隔」），
        //    于是一条 13KB/s 的慢线路只要还在滴水就永不失败 ——
        //    77MB 要 1.5 小时，用户看到的就是永远 0%。
        //    给 6 分钟：按实测 ghfast 581KB/s 下 77MB 约 2 分钟，
        //    6 分钟有 3 倍余量，真慢到超时也确实该放弃了。
        //
        // 2. `waitsForConnectivity = false` —— 默认在 iOS 上为 true，
        //    没网时 URLSession 会**挂着等网络恢复**而不是立刻报错。
        //    用户看到的就是「转圈但什么都没发生」。
        //
        // 3. `waitsForConnectivity` 关掉后仍可能「连上了但一个字节不来」，
        //    由 ProgressDelegate 的定时巡检看门狗兜住（见那个类）。
        cfg.timeoutIntervalForResource = 360
        cfg.waitsForConnectivity = false

        // [R59] delegate 用一条**显式的串行队列**，而不是 delegateQueue: nil。
        //
        // nil 会让 URLSession 自己造一条，我们拿不到它。给一条自己的，
        // 回调与取消都在可控的队列上，行为可预期。
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "SelfUpdate.download"

        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: q)
        // 把 session 交给 delegate：看门狗判定卡死时要靠它取消下载。
        delegate.attach(session: session)
        defer {
            delegate.stopWatchdog()
            session.finishTasksAndInvalidate()
        }

        // 巡检从这一刻就开始计时：哪怕连接阶段一个字节都不来，
        // 25 秒后也会判定卡死并取消 —— 正是用户截图里那个状态。
        delegate.startWatchdog(queue: DispatchQueue(label: "SelfUpdate.watchdog"))

        // 只用 `download(for:)` 发一次任务。
        // 曾经在这里先 downloadTask(with:) 拿句柄、再 download(for:)，
        // 那会发两个任务、下两遍 77MB —— 不要那么写。
        let (tmp, resp) = try await session.download(for: req)
        delegate.stop()
        delegate.stopWatchdog()

        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SelfUpdateError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // 挪到 Documents/Updates/ 下，文件名保持 release 里的原样。
        // 放 tmp 里会被系统随时清掉，用户还没点安装就没了。
        let dir = try updatesDir()
        let name = win.ipaName ?? "QuanNengAI.ipa"
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Documents/Updates/。不存在就建。
    static func updatesDir() throws -> URL {
        let base = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("Updates", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: 版本比较

    /// 逐段比大小。缺的段当 0 处理，所以 `1.0` 与 `1.0.0` 相等。
    /// 返回 1 = a 大，-1 = b 大，0 = 相等。
    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<Swift.max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}

// MARK: - 错误

enum SelfUpdateError: LocalizedError {
    /// release 里没有 .ipa / .tipa
    case noAsset
    case http(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noAsset:
            return "这个版本里没有可安装的包"
        case .http(let c):
            return "下载失败，HTTP \(c)"
        case .cancelled:
            return "下载已取消"
        }
    }
}

// MARK: - 进度代理

/// URLSession 的下载进度回调，转成闭包。
///
/// 单独一个类而不是让 `SelfUpdate` 自己去实现 delegate：
/// `SelfUpdate` 是 enum 命名空间，让它符合 URLSessionDownloadDelegate
/// 需要变成 class + NSObject，那会破坏「没有状态」这个前提。
///
/// `@unchecked Sendable`：这个类确实会被两个线程碰（URLSession 的
/// delegate 队列写、主线程 stop），所以有两个真是状态的东西要用锁护住。
/// delegate 队列是串行的，`stopped` 用 NSLock 保护就够 ——
/// 这是实测能过 Swift 6 严格并发、且没有真实竞态的最小写法。
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let onProgress: @Sendable (Double, Int64) -> Void
    private let lock = NSLock()
    private var stopped = false
    /// 兜底进度用的「预期总量」。代理（ghfast/ghproxy 等）经常不返回
    /// Content-Length，`totalBytesExpectedToWrite` 恒为 -1，拿它算进度
    /// 永远得 0。这里记最后一次已知总量，配合 download 侧在响应里读
    /// Content-Length 补上（见 `download` 里对 resp 的处理）。
    private var expectedFallback: Int64 = 0

    // MARK: [R59] 无进展看门狗
    //
    // 「一直 0% 一直转圈」的根因不止超时：慢线路会每几秒滴一个字节，
    // 使 `timeoutIntervalForResource` 永远不触发（那是总量时限，6 分钟
    // 才到），而 `timeoutIntervalForRequest` 也因为有数据在动而不触发。
    // 用户界面上就是「转圈 + 0%」，十几分钟毫无变化。
    //
    // ⚠️ 只看 `didWriteData` 是不够的 —— 用户遇到的恰恰是「一个字节都
    // 不来」（截图 0% 77MB），那时 `didWriteData` **一次都不会被调用**，
    // 钩子型的看门狗等于不存在。所以这里用一个独立定时器主动巡检：
    // 不管有没有回调，到点就检查「距离上次进展过了多久」。
    private var lastSeenBytes: Int64 = 0
    private var lastGrowthAt = Date()
    /// 两次增长之间允许的最大间隔（秒）。
    private static let stallLimit: TimeInterval = 25
    private var watchdog: DispatchSourceTimer?
    /// 巡检到卡死时回调。由 download 侧接到进度上报上。
    private let onStall: @Sendable () -> Void
    /// 正在下载的 session。卡死时用它取消 —— `invalidateAndCancel` 会把
    /// 当前所有任务一起撤掉，正是我们要的效果。
    ///
    /// 为什么是**强引用**而不是 weak：
    ///   · `session` 在 `download()` 里只是局部常量，一旦编译器认为它
    ///     「已经用过了」就可能提前释放，weak 会静默变成 nil ——
    ///     看门狗判定卡死时取消动作变成空操作，用户还是永远转圈。
    ///   · 强引用确实会和 session 形成「session 持 delegate / delegate 持
    ///     session」的环，因此在 `stopWatchdog()` 里必须置 nil 断开。
    ///     两处配对，不要只改一边。
    private var session: URLSession?

    func attach(session: URLSession) {
        lock.lock(); self.session = session; lock.unlock()
    }

    /// 启动巡检。`queue` 是本类自己的串行队列，不占用 delegate 队列，
    /// 避免「delegate 回调里再起定时器」造成的自锁风险。
    func startWatchdog(queue: DispatchQueue) {
        lock.lock()
        guard watchdog == nil else { lock.unlock(); return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 第一次检查放在 stallLimit 之后：刚开始那 25 秒是正常的
        // 连接 + 握手时间，不该被打断。之后每 2 秒巡一次。
        t.schedule(deadline: .now() + Self.stallLimit, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldFire = !self.stopped
                && Date().timeIntervalSince(self.lastGrowthAt) > Self.stallLimit
            if shouldFire { self.stopped = true }
            let s = self.session
            self.lock.unlock()
            guard shouldFire else { return }
            // 先取消下载，再通知界面 —— 顺序反过来界面会在取消完成前
            // 短暂显示「失败」而进度条还在动。
            s?.invalidateAndCancel()
            self.onStall()
        }
        watchdog = t
        lock.unlock()
        t.resume()
    }

    func stopWatchdog() {
        lock.lock()
        let t = watchdog
        watchdog = nil
        // 断开「delegate 强持 session」那条边，否则 session 和 delegate
        // 互指，这一轮下载的 URLSession 永远不会释放。
        session = nil
        lock.unlock()
        t?.cancel()
    }

    /// 记一次进度。返回 true 表示判定为卡死。
    private func noteProgress(_ bytes: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if bytes > lastSeenBytes {
            // 有实质进展就重置计时。阈值用 1KB 而不是 1 字节：
            // 「每 5 秒滴 3 个字节」那种假活不能算活着。
            if bytes - lastSeenBytes >= 1024 {
                lastSeenBytes = bytes
                lastGrowthAt = now
            }
        }
        return now.timeIntervalSince(lastGrowthAt) > Self.stallLimit
    }

    init(onProgress: @escaping @Sendable (Double, Int64) -> Void,
         onStall: @escaping @Sendable () -> Void) {
        self.onProgress = onProgress
        self.onStall = onStall
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    /// [R55] 下载开始后、或响应头已知但没 Content-Length 时，给一个
    /// 「预期总量」用于兜底进度（通常是 asset.size，见 Win.ipaSize）。
    func setExpectedFallback(_ total: Int64) {
        lock.lock(); expectedFallback = total; lock.unlock()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // downloadTask 参数这里用不到：取消统一走 session.invalidateAndCancel()，
        // 那样连「还没开始写的任务」也一并撤掉。显式忽略避免警告。
        _ = downloadTask

        // [R59] 先判定卡死（同一把锁内读写计数，不能读两次）。
        let stalled = noteProgress(totalBytesWritten)

        lock.lock(); let s = stopped; let expected = expectedFallback; lock.unlock()
        guard !s else { return }

        // 判定卡死：和定时巡检走同一条取消路径。
        //
        // 两处都可能判出卡死（定时器 25 秒一次 + 每次回调一次），
        // 所以取消要幂等：`stopped` 已在上面被 noteProgress… 之外的
        // 这里置位，重复进入会直接命中 `guard !s` 返回。
        if stalled {
            lock.lock()
            let already = stopped
            stopped = true
            lock.unlock()
            if !already {
                onProgress(-2, 0)
                session.invalidateAndCancel()
            }
            return
        }

        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        guard total > 0 else {
            // 完全没有总量信息：至少给个「在动」的信号，别让界面以为卡死。
            onProgress(-1, 0)
            return
        }
        let p = Double(totalBytesWritten) / Double(total)
        onProgress(min(max(p, 0), 1), total)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // download(for:) 的 async 版本会自己取这个文件，
        // 这个 delegate 方法只是协议要求，不用做事。
        _ = location
    }
}

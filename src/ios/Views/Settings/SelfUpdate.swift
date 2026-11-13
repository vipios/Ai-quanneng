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
    ///
    /// ⚠️ 这个仓是**隔离仓**（Ai-quanneng），不是定制仓（quanneng-ai）。
    /// 两仓各自出包、各自有滚动 tag `latest`，指错了就会装到另一条线的包。
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

        // [R60-按版本号判断] 三档，优先级从上到下：
        //
        //   1. 远端版本号 vs **本机版本号** —— 最可靠。
        //      2026-11-12 实测的 bug：本地 1.70、远端 v1.73，界面却显示
        //      「已是最新」。根因就是原来只有第 3 档（时间戳比较），
        //      而滚动 tag `latest` 的发布方式下时间戳判据会失真。
        //
        //   2. 远端版本号 vs **上次下载的版本号** —— 本机版本号读不到时用
        //      （理论上不会发生，Bundle 里一定有 CFBundleShortVersionString，
        //      留着是为了不因为一个字段缺失就退化成第 3 档）。
        //
        //   3. 时间戳兜底 —— 远端版本号解析不出来时（tag 是 `latest`、
        //      release name 里没数字）才用。
        let local = currentVersion
        let remoteVer = win.remoteVersion
        let downloaded = downloadedVersion

        let hasUpdate: Bool
        if !remoteVer.isEmpty && !local.isEmpty {
            hasUpdate = SelfUpdate.compare(remoteVer, local) > 0
        } else if !remoteVer.isEmpty && !downloaded.isEmpty {
            hasUpdate = SelfUpdate.compare(remoteVer, downloaded) > 0
        } else {
            // 兜底：远端拿不到版本号，只能看上传时间有没有变新。
            let remote = win.assetUpdatedAt
            let anchor = lastAssetUpdatedAt
            hasUpdate = anchor.isEmpty ? true : (remote > anchor)
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

    /// 上次**下载完成**那个包的版本号，如 `[1, 73]`。
    ///
    /// [R60-按版本号判断] 这是 `markInstalled` 那套锚点的补充。
    ///
    /// 为什么需要单独一份：`markInstalled` 写的是时间戳，而时间戳有两个毛病 ——
    ///   · 滚动 tag 下不同版本的更新时间可能相同（同一秒覆盖上传）
    ///   · 用户换设备后锚点丢失，只能退回「没锚点 = 有新版本」
    /// 版本号没有这两个问题，能直接跟远端比大小。
    ///
    /// 存成 `"1.73"` 这样的字符串而不是数组（UserDefaults 存不了数组的
    /// 类型安全版本，存 [Int] 要额外编码，得不偿失）。
    static var downloadedVersion: [Int] {
        get {
            let raw = UserDefaults.standard.string(forKey: "minis.selfupdate.downloadedVersion") ?? ""
            return parseVersionNumbers(raw)
        }
        set {
            let s = newValue.map(String.init).joined(separator: ".")
            UserDefaults.standard.set(s, forKey: "minis.selfupdate.downloadedVersion")
        }
    }

    /// 下载成功后调这个。
    ///
    /// [R60-下载锚点污染] **不要再叫它 markInstalled。**
    ///
    /// 原来这里叫 `markInstalled`，在 `savedFile = file` 之后立刻调用 ——
    /// 也就是「文件下到本地」那一刻，而用户还得在共享面板里走系统的安装
    /// 流程，那一步成功了没有 App 完全拿不到回调。
    ///
    /// 后果（2026-11-12 用户实测）：第一次下载失败 → 第二次下载成功、
    /// 弹出共享面板 → 安装报 301 没装上 → 第三次检查时锚点已经被写成
    /// 「已装这个版本」，界面显示「已是最新」，用户就再也升不上去了。
    ///
    /// 改名成 `markDownloaded` 是为了让语义诚实：我们只知道「下过了」，
    /// 不知道「装上了」。判断更新时拿它当第二档依据（见 `check()`），
    /// 而不是当成「已装」的绝对真相。
    static func markDownloaded(_ win: Win) {
        lastAssetUpdatedAt = win.assetUpdatedAt
        if !win.remoteVersion.isEmpty {
            downloadedVersion = win.remoteVersion
        }
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
        /// [R60-按版本号判断] 远端版本号的数字形式，如 `[1, 73]`。
        ///
        /// 为什么需要它：`buildLabel` 只是给眼睛看的字符串，之前真正用于
        /// 「有没有新版本」比较的是 `assetUpdatedAt` 时间戳。那套判据在
        /// 滚动 tag 的发布方式下会出错 —— 2026-11-12 实测：本地 1.70、
        /// 远端 v1.73，界面却显示「已是最新」。原因是锚点比的是上传时间，
        /// 而用户那次下载之后 asset 没有再被覆盖上传过（或者锚点被写脏了），
        /// 时间戳相等，于是判成最新。
        ///
        /// 版本号一直就在 `release.name`（「全能AI 1.73」）里，只是以前
        /// 解析出来仅用于显示。现在把它也拿去比大小。
        ///
        /// 拿不到（如 tag 就是 `latest`、name 里没数字）时为**空数组**，
        /// 调用方据此退回时间戳判断。
        var remoteVersion: [Int] = []
        /// [R59] 这条线路实测下载速度（B/s）。0 表示没测出/测不通。
        ///
        /// 有默认值：`probe` 里构造只带版本事实、不测速，`race` 最后
        /// 才把实测结果填进来。默认值让两处构造都不用改签名。
        var measuredSpeed: Double = 0
        /// [R82] 按实测速度排好序的线路，快的在前。
        ///
        /// 为什么要整份排序而不是只留赢家：下载阶段还会卡。原先只带一条
        /// 线路，那条一卡整次更新就失败，用户看到的是「这条线路太慢，已
        /// 自动放弃」。有了排序，下载可以依次往下试。
        var ranking: [Line] = []
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

        // [R82] 整份排序，交给下载阶段依次重试。
        //
        // 排序规则：测出速度的按速度从高到低；测不出速度的（0）
        // 排在后面、保持池内顺序 —— 它们不是「更慢」，是「未知」，
        // 真轮到它们的时候仍然值得一试，但没理由排在有实测值的线路前面。
        let measuredLines = measured
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
        let untested = lines.filter { l in !measuredLines.contains(where: { $0.id == l.id }) }
        // 一条都没测出速度时，把「API 探通过的那条」排到最前面：
        // 它是唯一有正面证据的线路，比池内顺序更值得先试。
        let ranking = measuredLines.isEmpty
            ? [fact.line] + untested.filter { $0.id != fact.line.id }
            : measuredLines + untested

        // 把「版本事实」和「下载线路」重新组合成一个 Win：
        // tag / 资产 / 大小 / updated_at 都来自 fact，
        // line 换成实测最快的那条（下载地址由 downloadURL 用它拼）。
        //
        // ⚠️ `remoteVersion` 必须显式带上。它在 `Win` 里有默认值 `[]`，
        // 漏传**编译器不会报错**，但会让 `check()` 永远拿到空数组、
        // 静默退回时间戳判断 —— 整个「按版本号比较」的修复就白做了。
        return Win(tag: fact.tag, line: bestLine, ms: fact.ms,
                   ipaName: fact.ipaName, ipaURL: fact.ipaURL, ipaSize: fact.ipaSize,
                   assetUpdatedAt: fact.assetUpdatedAt, buildLabel: fact.buildLabel,
                   remoteVersion: fact.remoteVersion,
                   measuredSpeed: bestSpeed,
                   ranking: ranking)
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
            //
            // [R60-按版本号判断] 同一段文字顺便解析成 `[1, 65]` 存进
            // `remoteVersion`，`check()` 拿它跟本地比大小。以前这里解析完
            // 只用于显示，比较还在用时间戳，于是「本地 1.70 / 远端 1.73」
            // 会显示「已是最新」。
            let name = obj["name"] as? String ?? ""
            let buildLabel: String
            var remoteVersion: [Int] = []
            if let m = name.range(of: "全能AI", options: []) {
                let tail = name[m.upperBound...].trimmingCharacters(in: .whitespaces)
                // tail 形如 "1.65"，去掉可能的 "· " 前缀
                let cleaned = tail.hasPrefix("·") ? String(tail.dropFirst()).trimmingCharacters(in: .whitespaces) : tail
                buildLabel = cleaned.isEmpty ? "v\(tag)" : "v\(cleaned)"
                remoteVersion = parseVersionNumbers(cleaned)
            } else if let m = name.range(of: "build", options: .caseInsensitive) {
                let tail = name[m.upperBound...].trimmingCharacters(in: .whitespaces)
                let num = tail.prefix(while: { $0.isNumber })
                buildLabel = num.isEmpty ? "v\(tag)" : "build \(num)"
                remoteVersion = parseVersionNumbers(String(num))
            } else {
                buildLabel = "v\(tag)"
                // tag 本身可能是版本号（如 1.73），也可能是滚动名（如 latest）。
                // 后者解析不出数字，返回空数组，`check()` 会退回时间戳判断。
                remoteVersion = parseVersionNumbers(tag)
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
                       assetUpdatedAt: assetUpdatedAt, buildLabel: buildLabel,
                       remoteVersion: remoteVersion)
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
        guard let raw = win.ipaURL, !raw.isEmpty else {
            throw SelfUpdateError.noAsset
        }

        // [R82-换线路重试] 从「一条线路下到底」改成「按实测速度依次试」。
        //
        // 之前竞速选出的那条线路一旦在下载阶段卡住，整次更新就结束了 ——
        // 用户的原话是「这个线路没有一次更新成功的，不是自动判定哪个最快吗」。
        // 测速只拉 256KB，握手时间占大头，选出来的「最快」本来就有误差；
        // 把一次测速当成一锤子买卖，遇到抖动就必然失败。所以下载阶段允许换。
        //
        // 最多试 3 条：一条 80MB，试太多等于让用户干等同一个结果。
        let order = win.ranking.isEmpty ? [win.line] : win.ranking
        let attempts = Array(order.prefix(3))

        var lastError: any Error = SelfUpdateError.allLinesFailed("没有可用线路")
        for (i, line) in attempts.enumerated() {
            // 换线路时先把进度归零，并给界面一个「在换、不是失败」的信号。
            if i > 0 { onProgress(-3, win.ipaSize) }
            do {
                return try await attemptDownload(line: line, rawURL: raw,
                                                 expectedSize: win.ipaSize,
                                                 name: win.ipaName,
                                                 onProgress: onProgress)
            } catch {
                // 让出主线程那种取消不是线路问题，不重试，直接往上抛。
                if error is CancellationError { throw error }
                lastError = error
            }
        }

        throw SelfUpdateError.allLinesFailed(
            (lastError as? any LocalizedError)?.errorDescription ?? lastError.localizedDescription
        )
    }

    /// 用**单条**线路下一次。成功时返回 Documents/Updates/ 里的最终路径。
    private static func attemptDownload(
        line: Line,
        rawURL: String,
        expectedSize: Int64,
        name: String?,
        onProgress: @escaping @Sendable (Double, Int64) -> Void
    ) async throws -> URL {
        guard let url = URL(string: line.prefix + rawURL) else {
            throw SelfUpdateError.noAsset
        }

        var req = URLRequest(url: url)
        // 大文件给足时间。9 秒是「测 API 通不通」的量级，
        // 下 80MB 用这个值会必然超时。
        req.timeoutInterval = 300
        req.setValue("Minis-SelfUpdate", forHTTPHeaderField: "User-Agent")

        let delegate = ProgressDelegate(
            onProgress: onProgress,
            // 卡死不再直接往界面报「失败」：取消任务会让 await 抛错，
            // 由 `download` 的循环决定换哪条线路，并统一发 -3。
            // 这里若抢先发 -2，界面会闪一下「这次更新失败了」再被改回来。
            onStall: {}
        )
        // [R55] 兜底总量用 release 里的 asset.size —— 代理不返回
        // Content-Length 时，进度用它来算百分比，不会一直转圈。
        delegate.setExpectedFallback(expectedSize)

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
        // initialGrace 之后也会判定卡死并取消，交给上层换线路。
        delegate.startWatchdog(queue: DispatchQueue(label: "SelfUpdate.watchdog"))

        // [R82-进度永远是 0 的根因] 这里必须自己发 downloadTask，
        // 不能用 `session.download(for:)` 那个 async 便捷方法。
        //
        // 那个方法内部自带一个 task 级 delegate，`didWriteData` **不会**
        // 转给我们这个 session delegate。三件事因此同时发生，正是用户
        // 报的现象：
        //   · 进度条全程 0（回调一次都没来过，totalBytes 只剩标题里那个 77MB）
        //   · 看门狗等不到「有进展」，25 秒准时把正在好好下载的任务掐掉
        //     →「这条线路太慢，已自动放弃」，于是没有一次更新成功
        //   · 偶尔网快、在 25 秒内下完 → 文件是好的，但进度还是 0
        //
        // 自己发任务就绕开了那层内部 delegate，回调必定走我们这里。
        // 曾经在这里先 downloadTask(with:) 拿句柄、再 download(for:)，
        // 那会发两个任务、下两遍 77MB —— 现在只用下面这一个 task。
        let task = session.downloadTask(with: req)
        let tmp: URL = try await withCheckedThrowingContinuation { cont in
            delegate.attachContinuation(cont)
            task.resume()
        }
        delegate.stopWatchdog()
        delegate.stop()

        // 自己发任务之后，状态码从 task.response 读；`resp` 那个元组已经没有了。
        guard let http = task.response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            try? FileManager.default.removeItem(at: tmp)
            throw SelfUpdateError.http((task.response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // [R60-下载结果校验] 校验拿到的**真的是那个 ipa**，不是一张 HTML。
        //
        // 这条是给 2026-11-12 那次「安装报 301」兜底的。
        //
        // 现场：用户第一次下载失败 → 第二次「像下载成功一样」弹出共享面板
        // → 在共享面板里点安装报 301 → 文件装不上。App 侧日志显示下载
        // 是成功的（HTTP 2xx、文件也确实落在 Documents/Updates/ 下）。
        //
        // 最合理的解释：加速前缀（ghfast / gh-proxy 这类）在某些情况下
        // 对 `releases/download/...` 这条路径返回的是一次**重定向响应体**
        // 或者一个 HTML 错误页，而不是二进制本体。URLSession 跟随重定向后
        // 拿到 200，于是我们以为下成功了；但落盘的那个文件根本不是 zip/ipa，
        // 系统安装器一读就报 301（它自己的错误码，跟 HTTP 301 无关）。
        //
        // 以前完全不校验大小，所以这种文件能一路走到共享面板。
        // 现在用 release 里记录的 asset.size 比对：偏差超过 1% 就判定
        // 「下的不是那个包」，直接报错，不弹共享面板 —— 让用户在 App 里
        // 就看到失败，而不是装的时候才遇到一个莫名其妙的 301。
        //
        // 为什么容差 1%：极少数代理会做 gzip 传输，落盘大小与 asset.size
        // 可能有细微差别；但这个包是 ipa（zip 容器，本身已压缩），
        // 代理再压也压不动，1% 足够宽松，同时又能挡住「几 KB 的 HTML 页」。
        if expectedSize > 0 {
            // 用 resourceValues 而不是 attributesOfItem[.size]：后者返回
            // `Any`，实际是 NSNumber，`as? Int64` 桥接不一定成立（会静默
            // 得到 0，等于校验被跳过）。`fileSize` 是明确的 Int?。
            let actual = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if actual > 0 {
                let diff = abs(Int64(actual) - expectedSize)
                let tolerance = max(Int64(64 * 1024), expectedSize / 100)
                if diff > tolerance {
                    try? FileManager.default.removeItem(at: tmp)
                    throw SelfUpdateError.badPayload(got: Int64(actual), expected: expectedSize)
                }
            }
        }

        // 挪到 Documents/Updates/ 下，文件名保持 release 里的原样。
        // 放 tmp 里会被系统随时清掉，用户还没点安装就没了。
        let dir = try updatesDir()
        let fileName = name ?? "QuanNengAI.ipa"
        let dest = dir.appendingPathComponent(fileName)
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

    /// 把任意版本文本解析成数字数组。
    ///
    /// 要能吃下这些形态（都来自真实 release 名）：
    ///   `1.73`         → [1, 73]
    ///   `v1.73`        → [1, 73]     （前导 v 被跳过）
    ///   `全能AI 1.73`  → [1, 73]     （中文被跳过，只在数字段取数）
    ///   `build 58`     → [58]
    ///   `1.73-beta`    → [1, 73]     （后缀不参与）
    ///   `latest`       → []          （纯字母，拿不到版本）
    ///   `""`           → []
    ///
    /// 为什么按「点分段、段内取前导数字」而不是正则抓全部数字：
    /// `1.73-beta2` 这种如果抓全部数字会得到 `[1,73,2]`，比 `[1,73]` 大，
    /// 于是「1.73 的预发布版」被判成比 1.73 新。按段取前导数字则得到
    /// `[1,73]`，与正式版相等，符合直觉。
    ///
    /// 注意 `任意非数字段会被整段跳过`，所以 `latest` 得到空数组 ——
    /// 调用方拿到空数组必须退回时间戳判断，不能当成 0。
    static func parseVersionNumbers(_ raw: String) -> [Int] {
        var out: [Int] = []
        for part in raw.split(separator: ".") {
            // 段内取前导数字（"73-beta" → 73）
            let digits = part.prefix(while: { $0.isNumber })
            if !digits.isEmpty {
                out.append(Int(digits) ?? 0)
                continue
            }
            // 该段不以数字开头（"v1" 的 v、"beta" 等）。可能是整串就一个
            // 词、数字在后面（"build58"），试着找段内第一段数字。
            let inner = part.drop(while: { !$0.isNumber })
            let num = inner.prefix(while: { $0.isNumber })
            if num.isEmpty {
                // 这一段完全没有数字。若已经解析出东西就停（"1.73-beta" 的
                // beta 段），否则继续看后面（"latest" 没有后继，结果是空）。
                if !out.isEmpty { break }
                continue
            }
            out.append(Int(num) ?? 0)
        }
        return out
    }

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
    /// [R60-下载结果校验] 下回来的东西大小对不上，多半是代理返回了
    /// 重定向页 / 错误页而不是 ipa 本体。见 `download` 里那段注释。
    case badPayload(got: Int64, expected: Int64)
    /// [R82] 依次试过的线路全部失败，`detail` 是最后一条线路的失败原因。
    case allLinesFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAsset:
            return "这个版本里没有可安装的包"
        case .http(let c):
            return "下载失败，HTTP \(c)"
        case .cancelled:
            return "下载已取消"
        case .badPayload(let got, let expected):
            // 说得具体一点：用户看到「大小不对」比看到「301」有用得多，
            // 也让他知道该换个网络/线路再试，而不是怀疑包本身坏了。
            let g = ByteCountFormatter.string(fromByteCount: got, countStyle: .file)
            let e = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
            return "下载到的文件不完整（\(g) / 应为 \(e)），像是代理返回了错误页。换个网络再试一次"
        case .allLinesFailed(let detail):
            return "3 条线路都没下成（\(detail)）。换个网络再试一次，或者稍后再点"
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
    /// [R82] 一次下载的等待者。任务结束时由 `finish(_:)` 唤醒，
    /// 而且只唤醒一次 —— 重复 resume 一个 continuation 会直接崩。
    private var continuation: CheckedContinuation<URL, any Error>?
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
    /// 第一次巡检的宽限（秒）。连接 + 重定向 + TLS 握手都在这段里，
    /// 一条线路头几秒没有任何字节是正常的，不该判它卡死。
    private static let initialGrace: TimeInterval = 30
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
        // 第一次检查放在 initialGrace 之后：连上、握手、首字节都在这段里。
        // 之后每 2 秒巡一次，判据是「距离上次实质增长超过 stallLimit」。
        //
        // [R82] 这个巡检现在才真正有意义：进度回调修好之后，
        // 只要数据在动 `lastGrowthAt` 就会被刷新；它判出的「没增长」
        // 是真没增长，不会是「回调根本没来」造成的误判。
        t.schedule(deadline: .now() + Self.initialGrace, repeating: 2)
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

    // MARK: [R82] 把任务结果交回 async 调用方

    /// 必须在 `task.resume()` **之前**调用 —— 先挂等待者再发任务，
    /// 否则回调可能早于等待者到达，`finish` 找不到人唤醒，
    /// 那个 `await` 就会一直挂着等到资源超时。
    func attachContinuation(_ c: CheckedContinuation<URL, any Error>) {
        lock.lock(); continuation = c; lock.unlock()
    }

    /// 唤醒等待者，且只唤醒一次。
    ///
    /// 一次正常下载会先后触发 `didFinishDownloadingTo` 和
    /// `didCompleteWithError`，两个都该收尾。取走 continuation 后置 nil，
    /// 第二次进来就是空操作 —— 这比用标志位简单，也不会漏。
    private func finish(_ result: Result<URL, any Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return }
        switch result {
        case .success(let url): c.resume(returning: url)
        case .failure(let error): c.resume(throwing: error)
        }
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
                // [R82] 只取消，不往界面报「失败」。
                // 取消会让 await 抛错，由 `download` 的循环决定换线路，
                // 并由它统一发 -3。这里再发一个 -2，界面会先闪一次
                // 「这次更新失败」再被改回来。
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
        // [R82] 这个回调返回之后，系统会立刻删掉 `location`，
        // 所以必须**当场**把文件搬到自己能控制的路径，不能只存个 URL
        // 回头再取 —— 之前 `download(for:)` 版本里这里什么都不做，
        // 是因为那个 async 方法自己搬；现在任务是我们自己发的。
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelfUpdate-\(UUID().uuidString).ipa")
        do {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: location, to: dst)
            finish(.success(dst))
        } catch {
            finish(.failure(error))
        }
    }

    /// 任务结束（正常或出错）。
    ///
    /// 正常结束时 `didFinishDownloadingTo` 已经把 continuation 用掉了，
    /// 这里就是空操作；它真正的作用是兜住**没拿到文件就结束**的情况
    /// （取消、断网、HTTP 层失败）—— 不兜的话 `await` 会一直挂到
    /// `timeoutIntervalForResource` 之后还没人叫醒。
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.failure(SelfUpdateError.cancelled))
        }
    }
}

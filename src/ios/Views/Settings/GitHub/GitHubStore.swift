//
//  GitHubStore.swift
//  Minis — GitHub 账号与编译路由的全局状态
//
//  ============================================================
//  为什么需要这一层
//
//  `GitHubAuth` 是普通类（不是 ObservableObject），原因和 `RelayVault`
//  一样：它里面全是同步读 UserDefaults + CryptoKit 的方法，
//  在做 @MainActor 会有隔离噪音，收益为零。
//
//  但界面必须能对它的变化作出反应。所以照 Relay 那套做法：
//  这一层是 @MainActor + ObservableObject，所有「界面关心的状态」
//  都从这里出，并且用一个 `revision` 计数器把普通类的变化
//  「翻译」成 SwiftUI 能看见的事件。
//  ============================================================

import Foundation
import SwiftUI

@MainActor
final class GitHubStore: ObservableObject {

    static let shared = GitHubStore()

    // MARK: - 账号状态

    /// 已登录账号。nil = 未登录
    @Published private(set) var account: GitHubAccount?
    /// App 有没有配 Client ID
    @Published private(set) var configured = false
    /// 账号/令牌被改写过就 +1。与 `RelayStore.vaultRevision` 同一套作用：
    /// 让读 `GitHubAuth.shared` 的界面也能重算 body。
    @Published private(set) var revision = 0

    // MARK: - 登录流程状态

    /// 正在发起的设备码。非 nil 时界面显示那 8 位码
    @Published private(set) var deviceCode: GitHubDeviceCode?
    /// 正在轮询
    @Published private(set) var polling = false
    @Published private(set) var loginError = ""
    /// 距离设备码过期的秒数，界面倒计时用
    @Published private(set) var secondsLeft = 0

    // MARK: - 工具链与编译路由

    /// 上次探测到的本机工具链
    @Published private(set) var toolchain: LocalToolchain?
    @Published private(set) var probingToolchain = false

    /// 最近一次编译的决策（用于界面显示「这次走了哪条路、为什么」）
    @Published private(set) var lastDecision: BuildDecision?
    /// 最近一次云端运行状态
    @Published private(set) var latestRun: WorkflowRun?
    /// 云端任务链接，编译跑起来后点它能去看日志
    @Published private(set) var runURL = ""

    // MARK: - 仓库配置镜像
    //
    // 这三个值本来住在 GitHubPush 里（UserDefaults）。
    // 界面直接绑 TextField 到 `GitHubPush.shared.repo` 是不行的 ——
    // 普通类不产生 SwiftUI 依赖。所以这里存一份镜像，
    // 保存时两边一起写。

    @Published var repoDraft = ""
    @Published var branchDraft = "main"
    @Published var workflowDraft = "build.yml"

    // MARK: - 总开关
    //
    // [T-minis-gh-fallback-switch] 用户要的那个「打开了才有兜底」的开关。
    //
    // 真值不在这一层，在 `AgentToolSwitch.githubBuild`（UserDefaults）。
    // 判「能不能兜底」一律走 `AgentToolSwitch.githubBuild.isEnabled`，
    // 别读这个镜像 —— 工具注册那边不在 MainActor 上，读不到 @Published。
    // 镜像只服务于界面渲染。

    @Published private(set) var fallbackEnabled = AgentToolSwitch.githubBuild.isEnabled

    /// 拨开关。写 UserDefaults + 刷镜像。
    func setFallbackEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: AgentToolSwitch.githubBuild.key)
        fallbackEnabled = on
    }

    /// 开关能拨上去的前提：登录 + scope 够 + 仓库配了。
    /// 不满足时界面把开关置灰 —— 打开一个什么也做不到的开关只会让人困惑。
    /// 置灰本身就把状态说完了，不需要再配一行小字解释。
    var canToggleFallback: Bool { GitHubPush.shared.isReady }

    /// 上一轮保存进 UserDefaults 的值。
    ///
    /// 用途单一：界面靠对比 draft 与 persisted 显示「未保存」。
    /// 没有它就只能靠 `onChange` 自动保存，而自动保存在
    /// 「归一化后回写 draft」时会把用户正在输入的中间态打断。
    @Published private(set) var persistedRepo = ""
    @Published private(set) var persistedBranch = "main"
    @Published private(set) var persistedWorkflow = "build.yml"

    // MARK: - 初始化

    private var countdownTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    private init() {
        reloadFromDisk()
    }

    /// 从普通类同步一份状态进来。冷启动与每次改动后都调。
    func reloadFromDisk() {
        configured = GitHubAuth.shared.isConfigured
        account = GitHubAuth.shared.account
        persistedRepo = GitHubPush.shared.repo
        persistedBranch = GitHubPush.shared.branch
        persistedWorkflow = GitHubPush.shared.workflowFile
        repoDraft = persistedRepo
        branchDraft = persistedBranch
        workflowDraft = persistedWorkflow
        fallbackEnabled = AgentToolSwitch.githubBuild.isEnabled
    }

    // MARK: - 派生状态

    var signedIn: Bool { account != nil && GitHubAuth.shared.hasToken }

    /// 三样都齐了：登录 + scope 够 + 仓库配了
    var canUseCloudBuild: Bool { GitHubPush.shared.isReady }

    /// 界面顶部那句状态
    var statusLine: String {
        // [R40-密令登录] 不再把「有没有 Client ID」当成前置条件。
        // 密令登录不依赖它，所以只在未登录时才提一句这件事。
        if !signedIn {
            return configured ? "未登录" : "未登录（可在本页用密令登录）"
        }
        if let a = account {
            if !a.missingScopes.isEmpty {
                return "已登录 \(a.login)，但缺 \(a.missingScopes.joined(separator: "、")) 权限"
            }
            return "已登录 \(a.login)"
        }
        return "已登录"
    }

    /// 云端能不能用的一句话解释，给编译器卡片用
    var cloudReadiness: String { GitHubPush.shared.readinessHint }

    // MARK: - 登录

    /// 发起登录：拿设备码，然后开始轮询。
    ///
    /// 这个方法是「一次性把流程跑起来」，界面只需要：
    ///   1. 调它
    ///   2. 等 `deviceCode` 出现就把码显示出来
    ///   3. 等 `signedIn` 变 true 就收起登录面板
    func startSignIn() {
        guard !polling else { return }
        loginError = ""
        deviceCode = nil
        secondsLeft = 0

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.runSignIn()
        }
    }

    private func runSignIn() async {
        polling = true
        defer { polling = false }

        do {
            let dc = try await GitHubAuth.shared.requestDeviceCode()
            self.deviceCode = dc
            startCountdown(to: dc.expiresAt)

            let acct = try await GitHubAuth.shared.pollToken(for: dc)
            // 成功
            self.account = acct
            self.deviceCode = nil
            self.loginError = ""
            self.revision += 1
            self.reloadFromDisk()
        } catch is CancellationError {
            // 用户主动取消，不算错误
        } catch {
            let msg = (error as? GitHubAuthError)?.errorDescription
                ?? error.localizedDescription
            self.loginError = msg
            self.deviceCode = nil
        }
    }

    /// 取消正在进行的登录（用户点了取消 / 关掉面板）
    func cancelSignIn() {
        pollTask?.cancel()
        pollTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        polling = false
        deviceCode = nil
        secondsLeft = 0
    }

    // MARK: - [R40-密令登录] 用现成令牌登录

    /// 密令登录的进行中标记。与 `polling` 分开：
    /// 一个是「在浏览器里等授权」，一个是「在校验你粘进来的令牌」，
    /// 界面文案和能不能取消都不一样，混用一个状态只会互相干扰。
    @Published private(set) var secretSigningIn = false

    /// 用密令登录。成功返回 nil，失败返回要显示给用户的一句话。
    ///
    /// 返回 String? 而不是 throw：这个方法的调用方是一个 SwiftUI 按钮，
    /// 那里本来就要么改 @State 要么什么都不做，让它自己 catch 一个
    /// LocalizedError 只是多一层壳。错误文案在这里就翻成人话。
    func signIn(withSecret raw: String) async -> String? {
        guard !secretSigningIn else { return nil }
        secretSigningIn = true
        loginError = ""
        defer { secretSigningIn = false }

        do {
            let acct = try await GitHubAuth.shared.signIn(withSecret: raw)
            account = acct
            loginError = ""
            revision += 1
            reloadFromDisk()
            return nil
        } catch {
            let msg = (error as? GitHubAuthError)?.errorDescription
                ?? error.localizedDescription
            loginError = msg
            return msg
        }
    }

    private func startCountdown(to end: Date) {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                let left = Int(end.timeIntervalSinceNow)
                await MainActor.run {
                    self?.secondsLeft = max(0, left)
                }
                if left <= 0 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - 令牌自检

    /// 设置页「测一下」用。失败会把本地令牌清掉并刷新界面。
    func verifyToken() async -> (ok: Bool, message: String) {
        let r = await GitHubAuth.shared.verifyToken()
        revision += 1
        reloadFromDisk()
        return r
    }

    // MARK: - 退出

    func signOut() {
        cancelSignIn()
        GitHubAuth.shared.signOut()
        account = nil
        // [T-minis-gh-fallback-switch] 退出登录必须连带关开关。
        //
        // 不关的话会留一个「开关是开的、但没令牌」的状态：第一二道门靠
        // isReady 还能挡住（没令牌 → isReady false），但设置页会显示
        // 「开 · 但还差条件」，而且用户下次重新登录会莫名其妙继承上次的
        // 开启状态。开关表达的意图是「我允许 AI 用云端编译」，登出即不再
        // 授权，如实归位到关。
        setFallbackEnabled(false)
        revision += 1
        reloadFromDisk()
    }

    // MARK: - 仓库配置

    /// 保存仓库 / 分支 / workflow 文件名。
    ///
    /// 做一点归一化：用户很可能从浏览器地址栏整条粘过来
    /// （`https://github.com/owner/repo`），直接存进去必然 404。
    ///
    /// 归一化后的值会回写到 draft —— 让用户看见实际存了什么，
    /// 而不是以为自己填的网址被原样接受了。
    func saveRepoConfig() {
        GitHubPush.shared.repo = Self.normalizeRepo(repoDraft)
        GitHubPush.shared.branch = normalizeBranch(branchDraft)
        GitHubPush.shared.workflowFile = normalizeWorkflow(workflowDraft)

        persistedRepo = GitHubPush.shared.repo
        persistedBranch = GitHubPush.shared.branch
        persistedWorkflow = GitHubPush.shared.workflowFile

        repoDraft = persistedRepo
        branchDraft = persistedBranch
        workflowDraft = persistedWorkflow
        revision += 1
    }

    /// `https://github.com/vipios/OpenMinis-build.git` → `vipios/OpenMinis-build`
    static func normalizeRepo(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        // 去掉协议与域名
        if s.contains("://") {
            s = s.replacingOccurrences(of: "https://", with: "")
                 .replacingOccurrences(of: "http://", with: "")
            if s.lowercased().hasPrefix("github.com/") {
                s = String(s.dropFirst("github.com/".count))
            }
            if s.lowercased().hasPrefix("www.github.com/") {
                s = String(s.dropFirst("www.github.com/".count))
            }
        }
        // 去掉 git@github.com: 形式
        if s.hasPrefix("git@github.com:") {
            s = String(s.dropFirst("git@github.com:".count))
        }
        // 去掉 .git 后缀与末尾斜杠
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        // 只保留前两段：owner/repo
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return s }
        return "\(parts[0])/\(parts[1])"
    }

    private func normalizeBranch(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasPrefix("refs/heads/") {
            s = String(s.dropFirst("refs/heads/".count))
        }
        return s.isEmpty ? "main" : s
    }

    private func normalizeWorkflow(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("/") { s.removeFirst() }
        if s.hasPrefix(".github/workflows/") {
            s = String(s.dropFirst(".github/workflows/".count))
        }
        return s.isEmpty ? "build.yml" : s
    }

    // MARK: - 工具链探测

    /// 探测 iSH 里的编译器。
    ///
    /// 实际执行交给 iSH（`ISHKernel`），这里只负责状态与解析。
    /// 传进来的 executor 由调用方提供 —— 这样这个文件不直接依赖
    /// iSH 的 Objective-C 头，单独也能编译（测试友好）。
    ///
    /// ⚠️ executor 的回调声明为 `@Sendable`：它会在 iSH 的后台线程上被调，
    ///    Swift 6 严格并发下不标就会报「捕获了非 Sendable 的 self」。
    ///    回调体里只做一件事 —— 跳回 MainActor 更新状态。
    func refreshToolchain(
        executor: @escaping @Sendable (String, @escaping @Sendable (String?, Error?) -> Void) -> Void
    ) {
        guard !probingToolchain else { return }
        probingToolchain = true
        executor(LocalToolchainProbe.probeScript) { output, _ in
            // 只把值传进去，不捕获取 self —— 保证 Sendable
            let parsed = output.map { LocalToolchainProbe.parse($0) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.probingToolchain = false
                if let tc = parsed {
                    self.toolchain = tc
                } else {
                    // 探测本身失败：iSH 起不来 / 命令超时。
                    // 给一个全 false 的结果，比留 nil 更好 ——
                    // 界面能显示「没检测到工具」，而不是一直转圈。
                    var tc = LocalToolchain()
                    tc.checkedAt = Date()
                    self.toolchain = tc
                }
            }
        }
    }

    // MARK: - 编译决策

    /// 算一次「这次该走哪条路」，把结果留在 `lastDecision` 给界面显示。
    ///
    /// 只做决策，不执行。真正的本机编译由 iSH 跑，
    /// 真正的云端编译由 `triggerCloudBuild` 跑。
    @discardableResult
    func decideRoute(
        previousAttempts: Int = 0,
        lastFailure: BuildFailureKind? = nil
    ) -> BuildDecision {
        let tc = toolchain ?? LocalToolchain()
        let d = BuildRouter.decide(
            toolchain: tc,
            previousAttempts: previousAttempts,
            lastFailure: lastFailure,
            cloudAvailable: canUseCloudBuild
        )
        lastDecision = d
        return d
    }

    // MARK: - 云端编译

    /// 推代码 + 触发 Actions + 等结果。
    ///
    /// - Parameters:
    ///   - files: 要推送的文件
    ///   - message: commit message
    ///   - inputs: workflow_dispatch 的输入
    func triggerCloudBuild(
        files: [RepoFile],
        message: String,
        inputs: [String: String] = [:],
        projectName: String = ""
    ) async throws {
        guard canUseCloudBuild else {
            throw GitHubPushError.notSignedIn
        }
        // [R53-自动推送目标] 已配置沿用旧仓库，没配置自动建仓。
        // 用户不用再手动填「推送目标」。
        _ = try await GitHubPush.shared.ensureTarget(projectName: projectName)
        lastDecision = BuildDecision(
            route: .github,
            reason: "推送 \(files.count) 个文件到 \(GitHubPush.shared.repo)",
            localAttempts: 0,
            lastFailure: .missingToolchain
        )

        _ = try await GitHubPush.shared.push(files: files, message: message)
        try await GitHubPush.shared.dispatchWorkflow(inputs: inputs)

        // dispatch 不返回 run id，稍等一下再去列表里找
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if let r = try? await GitHubPush.shared.latestRun() {
            latestRun = r
            runURL = r.htmlURL
        }
    }

    /// 刷新云端运行状态（界面下拉 / 定时调）
    func refreshRunStatus() async {
        guard canUseCloudBuild else { return }
        if let r = try? await GitHubPush.shared.latestRun() {
            latestRun = r
            runURL = r.htmlURL
        }
    }
}

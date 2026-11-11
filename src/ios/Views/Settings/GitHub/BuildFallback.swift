//
//  BuildFallback.swift
//  Minis — 编译路由：本机优先，GitHub 兜底
//
//  ============================================================
//  需求原话
//
//  「让 ai 不能本机编译的出的东西都用 GitHub 账号去推送来编译出来，
//    如果本机能编译出来就用本机，如果他能自己编译就自己去编译，
//    最后编译不出来的用 GitHub 账号推送去编译，GitHub 编译作为兜底使用。」
//
//  ============================================================
//  为什么是「三级」，不是「两级」
//
//  字面上是「本机 → GitHub」两级。但本机失败有两类：
//    · 真的缺能力（没编译器、没 SDK、内存不够）—— 直接该上云
//    · 偶发失败（超时、被杀、临时 OOM、网络抖动下载依赖失败）—— 重试就好
//  如果一失败就上云，偶发失败会白烧 Actions 额度（私有仓库每月 2000 分钟）。
//
//  所以中间插一层「本机重试一次」。这一层只在**看起来可重试**的错误上生效，
//  缺工具链这类确定性失败直接跳云端，不浪费一次重试的时间。
//  ============================================================
//
//  ⚠️ 本文件只负责「决定走哪条路」，不负责真正执行编译。
//     执行由 iSH 的 shell 和 GitHub Actions 各自负责，
//     这样职责清楚，上层调用方只关心 BuildDecision。
//  ============================================================

import Foundation

// MARK: - 走哪条路

/// 一次编译请求的最终归属
enum BuildRoute: String, Codable {
    /// 本机直接编（第一次尝试）
    case local
    /// 本机重试（第一次失败，但看起来是偶发）
    case localRetry
    /// 推 GitHub 用 Actions 编
    case github

    var label: String {
        switch self {
        case .local:      return "本机编译"
        case .localRetry: return "本机重试"
        case .github:     return "GitHub 云端编译"
        }
    }
}

// MARK: - 本机能力探测

/// iSH 沙箱里的工具链状态。
///
/// 探测方式：跑几条 `command -v`。**不跑 `--version`** ——
/// 那会真的启动编译器，慢且可能触发动态链接错误，
/// 我们只关心「有没有这个可执行文件」。
struct LocalToolchain: Codable, Equatable {
    var hasClang = false
    var hasGCC = false
    var hasMake = false
    var hasCMake = false
    var hasGit = false
    var hasPython = false
    var hasNode = false
    /// 探测时间，界面上显示「上次检测」
    var checkedAt = Date()

    /// 能不能编 C/C++/Objective-C 这类源码
    var canCompileNative: Bool { hasClang || hasGCC }
    /// 有没有构建系统（决定能不能处理带 Makefile/CMakeLists 的工程）
    var canRunBuildSystem: Bool { hasMake || hasCMake }

    /// 一句话摘要，给界面用
    var summary: String {
        var parts: [String] = []
        if hasClang { parts.append("clang") }
        if hasGCC { parts.append("gcc") }
        if hasMake { parts.append("make") }
        if hasCMake { parts.append("cmake") }
        if hasGit { parts.append("git") }
        if hasPython { parts.append("python") }
        if hasNode { parts.append("node") }
        return parts.isEmpty ? "没有任何编译工具" : parts.joined(separator: " · ")
    }
}

// MARK: - 失败分类
//
// 为什么要分类：决定「重试」还是「直接上云」。
// 分错的代价是双向的 —— 判成可重试会白等一次，
// 判成不可重试会把偶发失败直接推上云烧额度。

enum BuildFailureKind: Equatable {
    /// 缺编译器 / 缺 SDK / 缺头文件 —— 本机永远编不出来，直接上云
    case missingToolchain
    /// 内存不足 / 被系统杀掉 —— 重试有可能成
    case resourceExhausted
    /// 超时 —— 重试有可能成
    case timeout
    /// 网络类（下载依赖失败）—— 重试有可能成
    case network
    /// 源码本身有错 —— 重试多少次都一样，也不该推上云（云端也一样报错）
    case sourceError
    /// 认不出来的 —— 保守按可重试处理
    case unknown

    /// 本机重试有没有意义
    var worthRetryingLocally: Bool {
        switch self {
        case .missingToolchain:  return false   // 重试必然还是缺
        case .resourceExhausted,
             .timeout,
             .network,
             .unknown:           return true
        case .sourceError:       return false   // 源码错，换机器也一样错
        }
    }

    /// 该不该升级到 GitHub。
    ///
    /// 注意 `sourceError` **不升级** —— 这是关键取舍：
    /// 源码有语法错就推上云，等于花额度换一个一模一样的报错，
    /// 还会让用户以为「云端也没辙」。这种情况应该本机直接报错让人修。
    var shouldEscalateToCloud: Bool {
        switch self {
        case .missingToolchain:  return true    // 本机就是没有，只能上云
        case .resourceExhausted,
             .timeout,
             .network:           return true    // 本机扛不住 / 环境不行，云端可能行
        case .sourceError:       return false   // 上云也一样错，别浪费
        case .unknown:           return true    // 不确定，给云端一次机会
        }
    }
}

// MARK: - 从输出里认错误

enum BuildFailureClassifier {

    /// 从编译器 stderr/stdout 里判断失败类型。
    ///
    /// 规则来自常见编译器（clang/gcc）与 iSH 环境的实际输出。
    /// 宁可判成 `unknown`（会重试 + 上云）也不要误判成 `sourceError`
    /// （那会让本机直接失败、不重试也不上云）。
    static func classify(_ output: String, exitCode: Int32) -> BuildFailureKind {
        let s = output.lowercased()

        // 1. 源码错误 —— 先判这个，因为它可能同时包含别的关键词
        let sourceMarkers = [
            "error: expected", "error: use of undeclared identifier",
            "error: no member named", "error: cannot find symbol",
            "error: redefinition of", "error: too few arguments",
            "error: too many arguments", "error: invalid operands",
            "syntax error", "parse error", "undefined reference to",
        ]
        if sourceMarkers.contains(where: { s.contains($0) }) {
            return .sourceError
        }

        // 2. 缺工具链
        let toolMarkers = [
            "command not found", "no such file or directory: 'clang'",
            "clang: not found", "gcc: not found", "make: not found",
            "cmake: not found", "xcrun: error", "cannot execute binary file",
            "exec format error",          // 架构不对（x86 二进制跑在 arm 上）
            "standard library not found", "fatal error: 'stdio.h' file not found",
            "/usr/include/", "is not a valid sdk",
        ]
        if toolMarkers.contains(where: { s.contains($0) }) {
            return .missingToolchain
        }

        // 3. 资源
        let resourceMarkers = [
            "out of memory", "cannot allocate memory", "killed",
            "signal 9", "no space left on device", "oom",
        ]
        if resourceMarkers.contains(where: { s.contains($0) }) {
            return .resourceExhausted
        }

        // 4. 超时
        if s.contains("timed out") || s.contains("timeout") {
            return .timeout
        }

        // 5. 网络
        let netMarkers = [
            "could not resolve host", "connection refused", "network is unreachable",
            "ssl certificate", "temporary failure in name resolution",
            "failed to fetch", "connection reset",
        ]
        if netMarkers.contains(where: { s.contains($0) }) {
            return .network
        }

        // 6. 退出码非 0 但认不出 —— 保守
        return exitCode == 0 ? .unknown : .unknown
    }
}

// MARK: - 决策

/// 一条决策，带完整理由 —— 界面要能解释「为什么走这条」。
///
/// 用户原话里强调「GitHub 编译作为兜底使用」，
/// 所以任何一次升级到云端都必须能说清是为什么升的，
/// 不能给人「它自己偷偷跑去云端烧我额度」的感觉。
struct BuildDecision: Equatable {
    var route: BuildRoute
    /// 一句话理由，直接显示在界面上
    var reason: String
    /// 已经用掉的本机尝试次数
    var localAttempts: Int
    /// 触发升级的失败类型（本机直编成功时为 nil）
    var lastFailure: BuildFailureKind?

    var isCloud: Bool { route == .github }
}

enum BuildRouter {

    /// 本机最多试几次（含第一次）
    ///
    /// 2 = 第一次 + 重试一次。用户选的就是这个策略：
    /// 「本机重试一次再升级」。
    static let maxLocalAttempts = 2

    /// 决定下一步走哪。
    ///
    /// - Parameters:
    ///   - toolchain: 本机工具链探测结果
    ///   - previousAttempts: 已经失败过几次（0 表示还没试）
    ///   - lastFailure: 上次失败的类型（首次尝试时为 nil）
    ///   - cloudAvailable: GitHub 登录是否可用（token 在 + scope 够 + 配了仓库）
    static func decide(
        toolchain: LocalToolchain,
        previousAttempts: Int = 0,
        lastFailure: BuildFailureKind? = nil,
        cloudAvailable: Bool
    ) -> BuildDecision {

        // 1. 首次：本机能编就直接本机
        if previousAttempts == 0 {
            if toolchain.canCompileNative {
                return BuildDecision(
                    route: .local,
                    reason: "本机有 \(toolchain.hasClang ? "clang" : "gcc")，直接本机编",
                    localAttempts: 0,
                    lastFailure: nil
                )
            }
            // 本机没编译器 —— 这不是「失败」，是「压根做不到」
            // 不算浪费一次尝试，直接走云端
            if cloudAvailable {
                return BuildDecision(
                    route: .github,
                    reason: "本机没装编译器（\(toolchain.summary)），直接走 GitHub",
                    localAttempts: 0,
                    lastFailure: .missingToolchain
                )
            }
            // 两条路都不通，如实说清，不要假装能编
            return BuildDecision(
                route: .local,
                reason: "本机没编译器，GitHub 也没登录 —— 先装工具链或登录 GitHub",
                localAttempts: 0,
                lastFailure: .missingToolchain
            )
        }

        // 2. 已经试过若干次
        guard let failure = lastFailure else {
            // 说有失败次数但没失败类型 —— 调用方的状态不一致，
            // 保守当作可重试
            return fallthroughDecision(
                previousAttempts: previousAttempts,
                cloudAvailable: cloudAvailable,
                reason: "上次失败原因不明，\(previousAttempts < maxLocalAttempts ? "本机再试一次" : "走 GitHub")"
            )
        }

        // 2a. 缺工具链：重试没意义
        if failure == .missingToolchain {
            if cloudAvailable {
                return BuildDecision(
                    route: .github,
                    reason: "本机缺编译工具，重试也没用 —— 走 GitHub",
                    localAttempts: previousAttempts,
                    lastFailure: failure
                )
            }
            return BuildDecision(
                route: .local,
                reason: "本机缺编译工具，且 GitHub 没登录 —— 两条路都不通",
                localAttempts: previousAttempts,
                lastFailure: failure
            )
        }

        // 2b. 源码错：哪台机器都一样，不该上云烧额度
        if failure == .sourceError {
            return BuildDecision(
                route: .local,
                reason: "源码本身有错，换机器也一样报错 —— 先把代码改对",
                localAttempts: previousAttempts,
                lastFailure: failure
            )
        }

        // 2c. 还能本机重试
        if failure.worthRetryingLocally && previousAttempts < maxLocalAttempts {
            return BuildDecision(
                route: .localRetry,
                reason: "上次是\(failure.label)，本机再试一次",
                localAttempts: previousAttempts,
                lastFailure: failure
            )
        }

        // 2d. 该上云了
        if failure.shouldEscalateToCloud {
            if cloudAvailable {
                return BuildDecision(
                    route: .github,
                    reason: "本机\(previousAttempts)次没成功（\(failure.label)）—— 推到 GitHub 编",
                    localAttempts: previousAttempts,
                    lastFailure: failure
                )
            }
            return BuildDecision(
                route: .local,
                reason: "本机编不出来，但 GitHub 没登录 / 没配仓库 —— 先去登录",
                localAttempts: previousAttempts,
                lastFailure: failure
            )
        }

        return BuildDecision(
            route: .local,
            reason: "本机失败（\(failure.label)），且不适合上云",
            localAttempts: previousAttempts,
            lastFailure: failure
        )
    }

    private static func fallthroughDecision(
        previousAttempts: Int,
        cloudAvailable: Bool,
        reason: String
    ) -> BuildDecision {
        if previousAttempts < maxLocalAttempts {
            return BuildDecision(route: .localRetry, reason: reason,
                                 localAttempts: previousAttempts, lastFailure: .unknown)
        }
        if cloudAvailable {
            return BuildDecision(route: .github, reason: reason,
                                 localAttempts: previousAttempts, lastFailure: .unknown)
        }
        return BuildDecision(route: .local, reason: reason,
                             localAttempts: previousAttempts, lastFailure: .unknown)
    }
}

extension BuildFailureKind {
    var label: String {
        switch self {
        case .missingToolchain:  return "缺编译工具"
        case .resourceExhausted: return "内存不足"
        case .timeout:           return "超时"
        case .network:           return "网络问题"
        case .sourceError:       return "源码有错"
        case .unknown:           return "原因不明的失败"
        }
    }
}

// MARK: - 探测

enum LocalToolchainProbe {

    /// 在 iSH 里跑一遍 `command -v`，看有哪些工具。
    ///
    /// 用一条命令一次问完，不要一个个跑 ——
    /// 每次 exec 都有开销，一次拿全最快。
    ///
    /// 输出形如 `clang=1\ngit=0\n...`，解析简单且不受 locale 影响。
    static let probeScript = """
    for t in clang gcc make cmake git python3 node; do
      if command -v $t >/dev/null 2>&1; then echo "$t=1"; else echo "$t=0"; fi
    done
    """

    /// 解析探测输出
    static func parse(_ output: String) -> LocalToolchain {
        var tc = LocalToolchain()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=")
            guard parts.count == 2 else { continue }
            let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let ok = String(parts[1]).trimmingCharacters(in: .whitespaces) == "1"
            switch name {
            case "clang":  tc.hasClang = ok
            case "gcc":    tc.hasGCC = ok
            case "make":   tc.hasMake = ok
            case "cmake":  tc.hasCMake = ok
            case "git":    tc.hasGit = ok
            case "python3", "python": tc.hasPython = ok
            case "node":   tc.hasNode = ok
            default: break
            }
        }
        tc.checkedAt = Date()
        return tc
    }
}

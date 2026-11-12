import Foundation
import UIKit

/// The app's default outbound User-Agent for LLM provider requests.
///
/// Without an explicit header, URLSession sends `Minis/<CFBundleVersion>
/// CFNetwork/… Darwin/…` — i.e. the **build number** (e.g. `Minis/1`), not the
/// marketing version users recognize. This helper produces a stable, readable
/// default that carries the marketing version (CFBundleShortVersionString),
/// e.g. `Minis/1.10 (iOS 26.5; iPhone)`.
///
/// Scope: applied as the DEFAULT only where a request would otherwise fall back
/// to the system UA AND the endpoint does not require an identity-locked UA. A
/// user-set per-provider custom UA still overrides it, and OAuth/CLI-gated
/// flows (Codex `codex_cli_rs/…`, Claude Code `claude-cli/…`, Gemini/Antigravity
/// CLI UAs) keep their required UA untouched.
///
/// ⚠️⚠️ **这个字符串必须是纯 ASCII，不能换成中文「全能AI」。**
/// 2026-11-10 全量换字把它改成了 `全能AI/1.0 (iOS 17.0; iPhone)`，那是一颗雷：
///   · HTTP 头部按 RFC 只允许 ASCII 可见字符；
///   · CFNetwork 遇到含非 ASCII 的 header value，部分路径会直接抛
///     `NSInvalidArgumentException: Non-ASCII characters in header`，
///     请求根本发不出去 —— 表现是「所有模型都连不上」，而且跟模型无关；
///   · 就算没抛，服务商侧（Cloudflare、各家网关）也会按 latin-1 解出乱码。
/// 所以这里保留英文产品名。界面上用户看不到 UA，换成中文没有任何收益。
enum MinisUserAgent {
    /// Cached because the components are process-constant. `nonisolated(unsafe)`
    /// is safe: the value is computed once from immutable bundle/device info and
    /// only ever read thereafter.
    nonisolated(unsafe) private static var cached: String?

    static var `default`: String {
        if let cached { return cached }
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let device = UIDevice.current
        let osVersion = device.systemVersion          // e.g. "26.5"
        let model = device.model                        // "iPhone" / "iPad"
        let ua = "Minis/\(version) (iOS \(osVersion); \(model))"
        cached = ua
        return ua
    }
}

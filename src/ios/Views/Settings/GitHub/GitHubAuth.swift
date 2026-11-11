//
//  GitHubAuth.swift
//  Minis — GitHub 账号登录（OAuth Device Flow）
//
//  ============================================================
//  为什么用 Device Flow，不用「网页跳转授权」
//
//  1. TrollStore / 自签形态下，自定义 URL scheme 的回跳不可靠 ——
//     授权完可能回不到 App，用户卡在浏览器里。
//  2. 网页跳转要在 GitHub 上注册 OAuth App，Client Secret 得塞进
//     App 二进制里。塞进去等于公开，谁都能拿去冒充你的 App。
//     Device Flow 只用 Client ID（本来就是公开的），没有 Secret。
//  3. Device Flow 不需要回调地址、不需要服务器中转。
//
//  代价：用户要在浏览器里手输一次 8 位码。对自用完全可接受。
//  ============================================================
//
//  ⚠️ Client ID 需要你自己去 GitHub 建一个 OAuth App 拿。
//     建的时候勾选 "Enable Device Flow"，其它项随便填
//     （Homepage / Callback 都不用于 Device Flow）。
//     填好后写到 `MinisGitHub.clientID` —— 或者更规范地走
//     `src/ios/Configs/ProviderCustomization.xcconfig`，
//     和项目现有的注入方式保持一致。
//  ============================================================

import Foundation
import CryptoKit

// MARK: - 错误

enum GitHubAuthError: LocalizedError {
    /// 还没配 Client ID —— 这是开发者的配置问题，不是用户操作错
    case missingClientID
    /// 用户在浏览器里点了拒绝
    case denied
    /// 设备码过期（默认 900 秒），要重新发起
    case expired
    /// 用户在这台设备上已经授权过，但 token 保存失败
    case storageFailed
    case network(String)
    case http(Int)
    case badReply
    /// [R40-密令登录] 密令输入框是空的 / 只输了空格
    case emptySecret
    /// [R40-密令登录] 密令被 GitHub 判为无效（401）
    case badSecret
    /// [R40-密令登录] 令牌有效但账号被停用 / 被限流（403）
    case forbidden(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "还没有配置 GitHub Client ID。这是 App 的配置问题，不是你的操作问题。"
        case .denied:
            return "你在 GitHub 上拒绝了这次授权。"
        case .expired:
            return "验证码过期了，重新发起一次就行。"
        case .storageFailed:
            return "授权成功了，但令牌没能加密保存到本机。"
        case .network(let m):
            return "网络不通：\(m)"
        case .http(let c):
            return "GitHub 返回 HTTP \(c)。"
        case .badReply:
            return "GitHub 返回了看不懂的内容。"
        case .emptySecret:
            return "密令是空的。"
        case .badSecret:
            return "这串密令 GitHub 不认。可能复制少了字符、已经过期，或者已经被撤销。"
        case .forbidden(let m):
            return m.isEmpty ? "密令有效，但这个账号现在被 GitHub 拒绝了。" : m
        }
    }

    /// 错误文案里带「重新发起」「再试」这类可操作提示
    var isRetryable: Bool {
        switch self {
        case .expired, .network, .http: return true
        case .denied, .missingClientID, .storageFailed, .badReply: return false
        case .emptySecret, .badSecret, .forbidden: return false
        }
    }
}

// MARK: - 设备码

/// `POST https://github.com/login/device/code` 的结果
struct GitHubDeviceCode: Equatable {
    /// 8 位用户码，例如 `WDJB-MJHT`，要显示给用户去输
    let userCode: String
    /// 打开就能输码的地址（GitHub 固定返回，但保留字段以防变化）
    let verificationURI: String
    /// 轮询间隔（秒）。GitHub 可能要求 5 秒以上，别自己改小
    let interval: TimeInterval
    /// 这个设备码的绝对失效时间
    let expiresAt: Date
    /// 轮询时要带上的不透明串
    let deviceCode: String
}

// MARK: - 账号

/// 登录成功后的账号画像。只存展示用的东西，敏感值不进这里。
struct GitHubAccount: Codable, Equatable {
    var login: String
    var name: String?
    var avatarURL: String?
    /// token 实际拿到的权限范围。用来判断「够不够推代码」
    var scopes: [String]
    /// 登录时间，用于界面显示
    var signedInAt: Date

    /// [R40-密令登录] 权限范围读不到。
    ///
    /// 两条登录路线读 scopes 的方式不一样：
    ///   · 设备码登录 —— `access_token` 响应里直接给 `scope` 字段，一定有值；
    ///   · 密令登录   —— 只能读响应头 `X-OAuth-Scopes`。
    ///     **细粒度令牌（`github_pat_` 开头）这个头是空的**，
    ///     经典令牌（`ghp_` 开头）才有。
    ///
    /// 这种时候不能当成「一个权限都没有」——那会把用户的开关锁死在灰的，
    /// 明明令牌是好的却什么都干不了。所以单独标出来，判定时放行，
    /// 真没权限的话第一次推送会拿到 403，界面那时再说话。
    ///
    /// 用 optional 而不是带默认值的 Bool：`Codable` 合成出来的
    /// `init(from:)` 对带默认值的非 optional 属性仍然要求 key 存在，
    /// 老的存档（这个字段还不存在时写的）会直接解码失败、账号丢失。
    var scopeUnknown: Bool?

    var displayName: String {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        return login
    }

    /// 权限读不到 = 不知道，不是「没有」。
    private var unknown: Bool { scopeUnknown == true }

    /// 能不能往仓库写文件 / 触发 Actions。
    ///
    /// 推代码要 `repo`，触发 workflow_dispatch 要 `workflow`。
    /// 两者缺一，后面那条「本机编不出来推 GitHub」就跑不通 ——
    /// 所以在设置页要明确显示缺哪个，而不是等到用户点了编译才报错。
    var canPushCode: Bool { unknown || scopes.contains("repo") }
    var canTriggerWorkflow: Bool { unknown || scopes.contains("workflow") }

    var missingScopes: [String] {
        var m: [String] = []
        if !canPushCode { m.append("repo") }
        if !canTriggerWorkflow { m.append("workflow") }
        return m
    }
}

// MARK: - 认证管理器

/// GitHub 账号的唯一入口。所有 token 读写都走这里。
///
/// 与 `RelayVault` 同样的问题：它不是 ObservableObject，
/// 界面读它不构成 SwiftUI 依赖。所以：
///   · 这里加 `@Published` **不行**（它不是 MainActor 的 ObservableObject）
///   · 做法是让 `RelayStore` 那种「version 计数器」模式，见 `GitHubSession`
final class GitHubAuth {

    static let shared = GitHubAuth()
    private init() {}

    /// OAuth App 的 Client ID（公开值，不是秘密）
    ///
    /// ⚠️ 这是唯一需要你手动填的地方。
    ///     去 https://github.com/settings/developers → New OAuth App
    ///     → 勾 "Enable Device Flow" → 复制 Client ID。
    ///
    /// 留空时界面会明确说「没配 Client ID」，而不是给一个看不懂的
    /// 401 —— 配置缺失和用户操作错必须能区分开。
    static let clientID = ""

    /// 申请哪些权限。
    ///
    /// `repo`     —— 往私有仓库推代码、读仓库信息
    /// `workflow` —— 触发 / 修改 GitHub Actions 工作流
    ///               （没这个 scope 调 workflow_dispatch 会被 403）
    /// `read:user` —— 读自己的用户名和头像，用于界面显示
    ///
    /// 故意**不要** `delete_repo`、`admin:*` 这些。
    static let scopes = ["repo", "workflow", "read:user"]

    // MARK: 存储 key

    private let kTokenCipher = "minis.gh.token.cipher"
    private let kAccount     = "minis.gh.account"

    // MARK: - 状态

    var isConfigured: Bool { !Self.clientID.isEmpty }

    /// 有没有可用的 token。**只判断存在，不验证有效性** ——
    /// 验证要发网络请求，不该在 body 里同步调。
    var hasToken: Bool { token() != nil }

    /// 已登录的账号（可能为 nil：token 在但账号画像没存下来）
    var account: GitHubAccount? {
        guard let data = UserDefaults.standard.data(forKey: kAccount),
              let a = try? JSONDecoder().decode(GitHubAccount.self, from: data)
        else { return nil }
        return a
    }

    // MARK: - 第一步：拿设备码

    /// 发起一次登录。返回要显示给用户的 8 位码。
    ///
    /// 拿到之后界面要展示 `userCode` + `verificationURI`，
    /// 然后**同时**开始轮询 `pollToken(deviceCode:interval:expiresAt:)`。
    func requestDeviceCode() async throws -> GitHubDeviceCode {
        guard isConfigured else { throw GitHubAuthError.missingClientID }

        var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20

        // GitHub 的这个端点只收 form-encoded，不收 JSON
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
        ]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await send(req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw GitHubAuthError.http(code) }

        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let userCode = doc["user_code"] as? String,
              let deviceCode = doc["device_code"] as? String,
              let verify = doc["verification_uri"] as? String
        else { throw GitHubAuthError.badReply }

        // GitHub 给的是「过多少秒失效」，换算成绝对时间方便界面倒计时
        let expiresIn = (doc["expires_in"] as? Double) ?? 900
        // 轮询间隔默认 5 秒；给 0 或异常值时兜底到 5
        var iv = (doc["interval"] as? Double) ?? 5
        if iv < 5 { iv = 5 }

        return GitHubDeviceCode(
            userCode: userCode,
            verificationURI: verify,
            interval: iv,
            expiresAt: Date().addingTimeInterval(expiresIn),
            deviceCode: deviceCode
        )
    }

    // MARK: - 第二步：轮询拿 token

    /// 轮询直到成功 / 用户拒绝 / 过期。
    ///
    /// 这是 Device Flow 的标准行为：GitHub 会让你反复问
    /// 「用户授权了没」，在授权前返回 `authorization_pending`。
    /// 不要自己改快轮询频率 —— 太快会触发 `slow_down`，
    /// 反而更慢。
    func pollToken(for dc: GitHubDeviceCode) async throws -> GitHubAccount {
        var interval = dc.interval

        while Date() < dc.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 20

            var comps = URLComponents()
            comps.queryItems = [
                URLQueryItem(name: "client_id", value: Self.clientID),
                URLQueryItem(name: "device_code", value: dc.deviceCode),
                URLQueryItem(name: "grant_type",
                             value: "urn:ietf:params:oauth:grant-type:device_code"),
            ]
            req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

            let (data, resp) = try await send(req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw GitHubAuthError.http(status) }

            guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw GitHubAuthError.badReply
            }

            // 成功：拿到 access_token
            if let token = doc["access_token"] as? String, !token.isEmpty {
                let scopeStr = (doc["scope"] as? String) ?? ""
                let scopes = scopeStr.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                guard saveToken(token) else { throw GitHubAuthError.storageFailed }

                // 拿账号画像。失败不算登录失败 —— token 已经存进去了，
                // 只是显示不出头像而已，下次刷新会补上。
                let profile = await fetchProfile(token: token, scopes: scopes)
                return profile
            }

            // 失败：看 error 字段
            switch (doc["error"] as? String) ?? "" {
            case "authorization_pending":
                continue                      // 正常，用户还没输完
            case "slow_down":
                // GitHub 要求降速。它会在响应里给新的 interval
                interval = (doc["interval"] as? Double) ?? (interval + 5)
                continue
            case "expired_token":
                throw GitHubAuthError.expired
            case "access_denied":
                throw GitHubAuthError.denied
            default:
                // 其它错误（unsupported_grant_type / incorrect_client_credentials …）
                throw GitHubAuthError.badReply
            }
        }

        throw GitHubAuthError.expired
    }

    // MARK: - [R40-密令登录] 直接拿令牌登录

    /// 用一串已经存在的 GitHub 令牌登录，不走 Device Flow。
    ///
    /// ============================================================
    /// 为什么需要这条路
    ///
    /// 设备码登录要求 App 里有一个 OAuth App 的 Client ID。
    /// 这个改造版没有（也拿不到一个不会被滥用的），所以那条路在
    /// 当前包里永远是「未配置」。密令登录不依赖 Client ID：
    /// 用户在 GitHub 网页上自己建一个令牌，粘进来就行。
    ///
    /// 三种令牌都收
    /// ----------------------------------------------------------
    ///   ghp_  —— 经典令牌，最省事，scopes 由创建时勾选决定
    ///   github_pat_ —— 细粒度令牌，能精确到单个仓库，更安全，
    ///                  但响应头里不返回 scopes（见 scopeUnknown）
    ///   gho_ / ghu_ / ghs_ —— OAuth 与 App 令牌，用户可能从别处拿到
    ///
    /// 校验方式
    /// ----------------------------------------------------------
    /// 拿令牌打一次 `GET /user`：
    ///   · 200 → 有效。顺带把 login / 昵称 / 头像取回来，不用再请求一次。
    ///   · 401 → 令牌错了或已撤销。
    ///   · 403 → 令牌本身没问题，但账号被限 / 被停用，如实说。
    /// 只有 200 才落盘，避免存一个必然失败的令牌进去。
    ///
    /// 注意 `GET /user` 对**任何**有效令牌都返回 200，
    /// 包括权限极小的令牌 —— 所以这一步只证明「令牌是真的」，
    /// 不证明「够权限推代码」。够不够由 403 在真正推送时说话，
    /// 这里不假装能提前判死。
    /// ============================================================
    func signIn(withSecret raw: String) async throws -> GitHubAccount {
        // 粘贴常常带上首尾空格、换行、甚至 `Bearer ` 前缀
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("bearer ") {
            t = String(t.dropFirst("bearer ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 用户有时会把整段 `Token: ghp_xxx` 一起粘进来
        if let r = t.range(of: "ghp_", options: .caseInsensitive), r.lowerBound != t.startIndex {
            t = String(t[r.lowerBound...])
        } else if let r = t.range(of: "github_pat_", options: .caseInsensitive),
                  r.lowerBound != t.startIndex {
            t = String(t[r.lowerBound...])
        }
        guard !t.isEmpty else { throw GitHubAuthError.emptySecret }

        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub 要求带 UA
        req.setValue("Minis-GitHubAuth", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20

        let (data, resp) = try await send(req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0

        switch code {
        case 200:
            break
        case 401:
            throw GitHubAuthError.badSecret
        case 403:
            // 可能是限流，也可能是账号被限制。把 GitHub 的说法带出去，
            // 别自己编一句「令牌无效」——那是错的且会误导用户去重建令牌。
            let msg = Self.apiMessage(from: data)
            throw GitHubAuthError.forbidden(msg)
        default:
            throw GitHubAuthError.http(code)
        }

        // ── 解析账号画像 ──
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let login = doc["login"] as? String, !login.isEmpty
        else { throw GitHubAuthError.badReply }

        let name = doc["name"] as? String
        let avatar = doc["avatar_url"] as? String

        // ── 解析权限 ──
        //
        // 经典令牌会在响应头里回 `X-OAuth-Scopes: repo, workflow, read:user`。
        // 细粒度令牌不带这个头 —— 那就标记为「未知」，见 GitHubAccount.scopeUnknown。
        var scopes: [String] = []
        var unknown = false
        if let http = resp as? HTTPURLResponse {
            if let raw = http.value(forHTTPHeaderField: "X-OAuth-Scopes") {
                scopes = raw.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else if !t.hasPrefix("ghp_") {
                // 不是经典令牌、又没有 scopes 头 → 细粒度或 App 令牌，读不到
                unknown = true
            }
            // 经典令牌却没有这个头（理论上不会）→ 也当作读不到，别误判成零权限
            if t.hasPrefix("ghp_") && scopes.isEmpty {
                unknown = true
            }
        } else {
            unknown = true
        }

        // ── 落盘 ──
        // 走到这里令牌已被 GitHub 确认有效，才允许加密保存。
        guard saveToken(t) else { throw GitHubAuthError.storageFailed }

        let acct = GitHubAccount(
            login: login,
            name: name,
            avatarURL: avatar,
            scopes: scopes,
            signedInAt: Date(),
            scopeUnknown: unknown
        )
        if let enc = try? JSONEncoder().encode(acct) {
            UserDefaults.standard.set(enc, forKey: kAccount)
        }
        return acct
    }

    /// 从 GitHub 的错误体里抠出 `message`。
    /// 拿不到就给空串 —— 调用方会用兜底文案，不会显示一个空提示。
    private static func apiMessage(from data: Data) -> String {
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let m = doc["message"] as? String
        else { return "" }
        return m.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 账号画像

    /// 拉 `/user` 拿用户名、昵称、头像。失败时给一个最小可用画像。
    private func fetchProfile(token: String, scopes: [String]) async -> GitHubAccount {
        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.timeoutInterval = 20

        var login = ""
        var name: String?
        var avatar: String?

        if let (data, resp) = try? await send(req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            login = (doc["login"] as? String) ?? ""
            name = doc["name"] as? String
            avatar = doc["avatar_url"] as? String
        }

        let acct = GitHubAccount(
            login: login.isEmpty ? "github-user" : login,
            name: name,
            avatarURL: avatar,
            scopes: scopes,
            signedInAt: Date()
        )
        if let data = try? JSONEncoder().encode(acct) {
            UserDefaults.standard.set(data, forKey: kAccount)
        }
        return acct
    }

    /// 用已存的 token 重新拉一次画像（设置页下拉刷新时调）
    func refreshAccount() async -> GitHubAccount? {
        guard let t = token() else { return nil }
        let existing = account
        return await fetchProfile(token: t, scopes: existing?.scopes ?? [])
    }

    // MARK: - 验证 token 还有没有效

    /// 打一次 `/user` 确认 token 没被吊销。设置页「测一下」用。
    ///
    /// 返回 (是否有效, 说明)。无效时清掉本地 token —— 留着一个
    /// 坏 token 只会让后面每次推送都失败，还查不出原因。
    func verifyToken() async -> (ok: Bool, message: String) {
        guard let t = token() else { return (false, "还没登录") }

        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.timeoutInterval = 20

        guard let (_, resp) = try? await send(req) else {
            return (false, "网络不通，没测出来")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            return (true, "令牌有效")
        case 401:
            // 令牌被吊销或过期 —— 清掉，让界面回到「未登录」
            signOut()
            return (false, "令牌已失效，需要重新登录")
        default:
            return (false, "GitHub 返回 HTTP \(code)")
        }
    }

    // MARK: - 退出

    /// 退出登录。
    ///
    /// 只清本机，不调 GitHub 的 revoke 接口 ——
    /// 那个接口要 Client Secret，我们故意不带。
    /// 用户真要在服务端撤销，去 GitHub 设置里删授权即可。
    /// 界面上要把这句话写清楚，别让人以为「退出 = 已撤销」。
    func signOut() {
        UserDefaults.standard.removeObject(forKey: kTokenCipher)
        UserDefaults.standard.removeObject(forKey: kAccount)
    }

    // MARK: - token 读写（复用 RelayVault 的加密思路）

    /// 读 token。解不开就清掉坏密文并返回 nil。
    func token() -> String? {
        guard let s = UserDefaults.standard.string(forKey: kTokenCipher), !s.isEmpty else {
            return nil
        }
        guard let plain = Self.open(s) else {
            // 设备标识变了（换机 / 还原备份）会解不开。
            // 留着坏密文没意义，清掉让用户重新登录。
            UserDefaults.standard.removeObject(forKey: kTokenCipher)
            return nil
        }
        return plain
    }

    private func saveToken(_ token: String) -> Bool {
        guard let sealed = Self.seal(token) else { return false }
        UserDefaults.standard.set(sealed, forKey: kTokenCipher)
        return true
    }

    // MARK: - AES-GCM
    //
    // 与 RelayVault 同一套做法：不用 Keychain（TrollStore 形态下不可靠），
    // 密钥由「设备标识 + 固定盐」派生，密文存 UserDefaults。

    private static func deviceIdentity() -> String {
        // 与 RelayVault 保持同样的回落逻辑：IDFV 拿不到时用
        // 自己持久化的 UUID，保证任何时刻派生出同一把密钥。
        let key = "minis.gh.vault.id"
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }

        #if canImport(UIKit)
        if let idfv = UIKit.UIDevice.current.identifierForVendor?.uuidString, !idfv.isEmpty {
            UserDefaults.standard.set(idfv, forKey: key)
            return idfv
        }
        #endif

        let gen = UUID().uuidString
        UserDefaults.standard.set(gen, forKey: key)
        return gen
    }

    /// 派生密钥用的固定盐。
    ///
    /// ⚠️⚠️ 保持 `Minis.` 前缀，**换字的时候不要动它**。
    /// 2026-11-10 那次全量换字把它改成了「全能AI.」，后果是：老用户机器上
    /// 已存的 GitHub token 是用旧盐派生的密钥加密的，新盐派生出另一把密钥
    /// → 一个都解不开，而且解不开的密文会被当成坏数据清掉。
    /// 这是一段密钥材料，不是界面文案，界面上永远不显示它。
    private static let keySalt = "Minis.GitHubAuth.v1"

    private static func symmetricKey() -> SymmetricKey {
        let raw = SHA256.hash(data: Data((deviceIdentity() + keySalt).utf8))
        return SymmetricKey(data: Data(raw))
    }

    private static func seal(_ plain: String) -> String? {
        guard let box = try? AES.GCM.seal(Data(plain.utf8), using: symmetricKey()),
              let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    private static func open(_ sealed: String) -> String? {
        guard let data = Data(base64Encoded: sealed),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: symmetricKey())
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: - 发请求

    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = req.timeoutInterval > 0 ? req.timeoutInterval : 20
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        do {
            return try await session.data(for: req)
        } catch {
            throw GitHubAuthError.network(error.localizedDescription)
        }
    }
}

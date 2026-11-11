//
//  RelayVault.swift
//  Minis — 中转站 / 路由器地址与密码存储
//
//  需求：「只需要输入第一次密码，以后都不需要密码进去」。
//
//  ============================================================
//  为什么不用 Keychain
//
//  Minis 可能以自签 / TrollStore 形态安装，这类形态下 entitlements 受限，
//  Keychain 不可靠（Cabin 项目同样结论）。所以：
//    · 密码用 AES-GCM 加密后存 UserDefaults
//    · 密钥由「设备标识 + 应用固定盐」派生 —— 换机/拷到别处就解不开
//    · 明文只在内存里短暂存在，不落盘、不写日志
//
//  ============================================================
//  ⚠️ 地址只在这里存一份，别处（界面 / 判定 / 请求）全部读这里。
//
//  历史上的坑：Vault 存完整 URL、别处另存一个 host，两处各自写，
//  结果「设置里改了域名，实际还在连旧域名」。
//  ============================================================

import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

final class RelayVault {

    static let shared = RelayVault()
    private init() {}

    /// 全部 key 加前缀，避免与 Minis 自身的 UserDefaults 键撞车
    private let kCipher   = "minis.relay.pass.cipher"
    private let kHome     = "minis.relay.host.home"
    private let kAway     = "minis.relay.host.away"
    private let kRouterKey = "minis.relay.router.key.cipher"
    // 与 kEnabled / enabled 一起删掉的还有一个 "minis.relay.enabled" 键。

    /// 家里中转站的内网地址（默认值）。
    /// ⚠️ 隐私：这里**绝不能**写作者自己的真实地址/域名。ipa 会分发给别人，
    /// 若把真实内网 IP 或 DDNS 域名硬编码成默认值，任何人装上 App 就会
    /// 在输入框里看到你的真实地址，且未配置时会直接尝试连你的中转站。
    /// 所以默认留空 —— 用户自己填。占位提示用「举例」放在界面层。
    static let defaultHomeHost = ""
    /// 公网域名（Cloudflare 隧道），443 上同时提供 relay 和 airboot
    static let defaultAwayHost = ""

    // 这里原来有一个 `var enabled: Bool`（读写 `minis.relay.enabled`），
    // 打算做「设置页入口开关」。全仓库没有任何地方读它，属于死代码，
    // 已删。真要做开关时再加 —— 加的时候记得同时决定「关掉之后
    // 已有的中转站档案怎么办」，而不是只加一个没人读的 flag。

    // MARK: - 密码

    func save(password: String) {
        let p = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else {
            UserDefaults.standard.removeObject(forKey: kCipher)
            return
        }
        guard let sealed = Self.seal(p) else { return }
        UserDefaults.standard.set(sealed, forKey: kCipher)
    }

    /// 取密码。解不开（换机了 / 数据被拷走）返回 nil，并且顺手清掉坏密文
    /// —— 否则界面会误以为「已经存过密码」，然后拿空密码去请求。
    func password() -> String? {
        guard let s = UserDefaults.standard.string(forKey: kCipher), !s.isEmpty else { return nil }
        guard let p = Self.open(s, storageKey: kCipher) else {
            UserDefaults.standard.removeObject(forKey: kCipher)
            return nil
        }
        return p.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasPassword: Bool { password() != nil }

    func clearPassword() { UserDefaults.standard.removeObject(forKey: kCipher) }
    // MARK: - 路由器专用密钥（airboot 的 k 参数）

    /// 路由器指令用的 key。历史数据里它与后台密码常常是同一个值，
    /// 但两者是两条独立服务，故意分开存：改后台密码不会连带把
    /// 路由器指令打挂。为空时上层回落用后台密码。
    func saveRouterKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else {
            UserDefaults.standard.removeObject(forKey: kRouterKey)
            return
        }
        guard let sealed = Self.seal(k) else { return }
        UserDefaults.standard.set(sealed, forKey: kRouterKey)
    }

    func routerKey() -> String? {
        guard let s = UserDefaults.standard.string(forKey: kRouterKey), !s.isEmpty else { return nil }
        guard let k = Self.open(s, storageKey: kRouterKey) else {
            UserDefaults.standard.removeObject(forKey: kRouterKey)
            return nil
        }
        let t = k.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 发指令时实际用的 key：优先路由器专用，没配过就用后台密码
    var effectiveRouterKey: String {
        routerKey() ?? password() ?? ""
    }

    // MARK: - 地址（只存 host，协议和端口由 RelayRoute 决定）

    var homeHost: String {
        // 函数名是 cleanHost（下面 124 / 143 行两个重载），不是 clean。
        // 之前写成 Self.clean 是编译错误：number of errors 里报
        // "type 'Self' has no member 'clean'" —— 一直被 WMO 的 OOM
        // 掩盖着，换 singlefile 后才露出来。
        get { Self.cleanHost(UserDefaults.standard.string(forKey: kHome), fallback: Self.defaultHomeHost) }
        set { UserDefaults.standard.set(Self.cleanHost(newValue, fallback: Self.defaultHomeHost), forKey: kHome) }
    }

    var awayHost: String {
        get { Self.cleanHost(UserDefaults.standard.string(forKey: kAway), fallback: Self.defaultAwayHost) }
        set { UserDefaults.standard.set(Self.cleanHost(newValue, fallback: Self.defaultAwayHost), forKey: kAway) }
    }

    // MARK: - 路由器型号（纯展示）

    /// 路由器页顶部那行「型号」。**不是探测出来的** ——
    /// airboot 的响应里没有型号字段，MT7621 这类信息后端也没回。
    /// 硬编一个等于在界面上写假话，所以让用户自己填一次，留空就显示「未配置」。
    ///
    /// 不加密：型号不是秘密，而且要在列表里直接读。
    private let kRouterModel = "minis.relay.router.model"

    var routerModel: String {
        get {
            let v = (UserDefaults.standard.string(forKey: kRouterModel) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return v
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty {
                UserDefaults.standard.removeObject(forKey: kRouterModel)
            } else {
                UserDefaults.standard.set(v, forKey: kRouterModel)
            }
        }
    }

    /// 用户可能整段粘一个 URL 进来（http://a.b:8080/x），这里只保留 host。
    /// 空值一律回落默认值 —— 空格子等于「没配」，不能让 RelayRoute 拿到空 host。
    ///
    /// 注意：**端口一律剥掉**。端口由 RelayRoute 按线路决定
    /// （内网 8080 / 域名 443），用户填 port 只会造成两套说法打架。
    static func cleanHost(_ raw: String?, fallback: String) -> String {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return fallback
        }
        if v.contains("://") {
            if let h = URL(string: v)?.host, !h.isEmpty { v = h }
        }
        if let slash = v.firstIndex(of: "/") {
            v = String(v[v.startIndex..<slash])
        }
        if let colon = v.firstIndex(of: ":") {
            // 允许 IPv6 方括号写法，其余按「host:port」截掉端口
            if !v.hasPrefix("[") { v = String(v[v.startIndex..<colon]) }
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? fallback : v
    }

    /// 对外的简写入口（判定与界面都走这个，保证归一化规则只有一份）
    static func cleanHost(_ raw: String?) -> String {
        cleanHost(raw, fallback: "")
    }

    // MARK: - AES-GCM

    /// 派生密钥用的设备标识。
    ///
    /// ⚠️ 这里**不能**直接用 `identifierForVendor`：它在两种情况下为 nil ——
    ///    · App 首次启动、设备尚未解锁时偶尔拿不到
    ///    · 同一 vendor 的 App 全部卸载后系统会重置 IDFV
    /// 一旦某个时刻拿了 nil 存下密码，等 IDFV 变成非 nil，之前存的密文
    /// 就再也解不开 —— 而 `password()` 解不开时会**清掉坏密文**。
    /// 表现就是：用户明明填过密码，某天打开 App 又被要求重输，
    /// 直接违反「只输一次」。
    ///
    /// 所以：IDFV 拿不到时回落到「自己生成一个 UUID 并持久化」的稳定标识，
    /// 保证任何时刻都能派生出同一把密钥。
    private static let kVaultID = "minis.relay.vault.id"

    private static func deviceIdentity() -> String {
        #if canImport(UIKit)
        if let id = UIDevice.current.identifierForVendor?.uuidString, !id.isEmpty {
            return id
        }
        #endif
        // 回落到自持久化的 UUID —— 只写一次，之后永远稳定
        if let saved = UserDefaults.standard.string(forKey: kVaultID), !saved.isEmpty {
            return saved
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: kVaultID)
        return fresh
    }

    /// 派生密钥用的固定盐。
    ///
    /// ⚠️⚠️ 这里是 `Minis.` 而不是 `全能AI.`，**故意的，不要再换字的时候改它**。
    /// 2026-11-10 全量换字（Minis → 全能AI）把这一行也改了，后果是：
    ///   用户机器上已经存着的密文是用 `Minis.RelayAdmin.v1` 派生的密钥加的，
    ///   换成新盐之后派生出另一把密钥 → 老密文一律解不开 →
    ///   `password()` 还会把「打不开的密文」当成坏数据直接删掉。
    ///   表现就是：升级一次，之前记住的后台密码凭空消失，要重新输一遍，
    ///   用户完全看不出为什么。
    ///
    /// 这个字符串不是给人看的文案，是**密钥材料**。界面上一个字都不显示它，
    /// 改成中文没有任何收益，只会让老数据全废。所以保持原样。
    private static let keySalt = "Minis.RelayAdmin.v1"

    private static func derivedKey() -> SymmetricKey {
        let seed = SHA256.hash(data: Data((deviceIdentity() + keySalt).utf8))
        return SymmetricKey(data: Data(seed))
    }

    /// 旧版本派生密钥时用的身份串（`identifierForVendor`，拿不到就写死 "no-idfv"）。
    /// 只用于**解密迁移**：老密文要用老密钥才能打开，打开后立刻用新密钥重存。
    /// 新代码不再用它加密任何东西。
    private static func legacyKeys() -> [SymmetricKey] {
        var ids: [String] = []
        #if canImport(UIKit)
        if let id = UIDevice.current.identifierForVendor?.uuidString, !id.isEmpty {
            ids.append(id)
        }
        #endif
        ids.append("no-idfv")
        return ids.map { SymmetricKey(data: Data(SHA256.hash(data: Data(($0 + keySalt).utf8)))) }
    }

    private static func seal(_ plain: String) -> String? {
        guard let box = try? AES.GCM.seal(Data(plain.utf8), using: derivedKey()),
              let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    /// 打开一段密文。
    ///
    /// 先用当前密钥；打不开再挨个试一遍 legacy 密钥 —— 老版本装过、
    /// 这次升级上来的用户就是这样把密码带过来的。**只要能用老密钥打开，
    /// 就立刻改用当前密钥重存到 `storageKey`**，下次不必再试老密钥。
    ///
    /// storageKey 必须是调用方自己的存储位（密码位 / 路由密钥位），
    /// 传错会把值写到别人的格子里。
    private static func open(_ cipher: String, storageKey: String) -> String? {
        guard let data = Data(base64Encoded: cipher),
              let box = try? AES.GCM.SealedBox(combined: data) else { return nil }

        if let plain = try? AES.GCM.open(box, using: derivedKey()) {
            return String(data: plain, encoding: .utf8)
        }

        // 老密钥迁移
        for legacy in legacyKeys() {
            if let plain = try? AES.GCM.open(box, using: legacy),
               let text = String(data: plain, encoding: .utf8) {
                if let sealed = seal(text) {
                    UserDefaults.standard.set(sealed, forKey: storageKey)
                }
                return text
            }
        }
        return nil
    }
}

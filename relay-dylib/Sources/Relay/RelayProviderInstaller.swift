//
//  RelayProviderInstaller.swift
//  RelayDylib — 把「中转站」写成 App 里的一条服务商
//
//  这一层只做三件事：拼 payload、切到后台线程调 ObjC 桥、把 envelope
//  翻译成一句人话。真正的写入在 App 自己的代码里（见 RelayBridge.m 顶部）。
//

import Foundation

// MARK: - 调 ObjC 桥

/// ObjC 侧的实现（RelayBridge.m）。走 C 符号而不是 ObjC 消息，
/// 是因为 App 的类名带模块前缀、编译期不可知 —— 类在运行时按后缀找，
/// 这个函数只负责把 payload 递进去。
@_silgen_name("RelayConfigAddProvider")
private func RelayConfigAddProvider(_ payload: NSDictionary) -> NSDictionary?

// MARK: - 结果

enum RelayAddProviderOutcome {
    /// 已经写进去了。`instanceId` 是 App 生成的服务商 id。
    case added(label: String, instanceId: String)
    /// 没写成。`title` 给人看的一句话，`detail` 是原始原因。
    case failed(title: String, detail: String)

    var alertTitle: String {
        switch self {
        case .added:  return "已添加"
        case .failed(let title, _): return title
        }
    }

    var alertMessage: String {
        switch self {
        case .added(let label, let instanceId):
            // 模型列表是 App 自己按 /v1/models 拉的，异步、不阻塞。
            return "「\(label)」已写进 App 的服务商列表。\n\n"
                + "App 正在按它的 /v1/models 拉模型，几秒后回到模型选择就能看到。\n\n"
                + "instanceId: \(instanceId.prefix(8))…"
        case .failed(_, let detail):
            return detail
        }
    }
}

// MARK: - 安装器

enum RelayProviderInstaller {

    /// 表单提交入口：关页面 → 调写入通道 → 弹结果。
    ///
    /// 为什么必须先关页面：App 的确认弹窗（ConfigConfirmSheet）是挂在
    /// App 自己的根视图上的，而我们整个浮层窗口在 .alert+1、盖在 App 之上。
    /// 面板开着时弹窗会被压在后面 —— 用户看不到，30 秒后超时算「没确认」。
    /// 所以顺序是「先关、再写」，宁可页面闪一下，也不能让确认弹窗隐形。
    /// （关掉面板后浮层只剩全透明、触摸穿透的根视图，不挡确认弹窗。）
    ///
    /// 两个延时：0.45s 等关闭动画走完（否则弹窗挂在正在消失的视图上），
    /// 0.6s 等确认弹窗收回去（否则结果 alert 抢不到顶层）。
    static func submit(label: String,
                       providerType: String,
                       baseURL: String,
                       apiKey: String,
                       appendV1: Bool) {
        RelayBallInstaller.shared.closeHome()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            add(label: label,
                providerType: providerType,
                baseURL: baseURL,
                apiKey: apiKey,
                appendV1: appendV1) { outcome in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    RelayBallInstaller.shared.presentAlert(
                        title: outcome.alertTitle,
                        message: outcome.alertMessage
                    )
                }
            }
        }
    }

    /// 加一条服务商。
    ///
    /// - Parameters:
    ///   - label: 显示名（App 要求唯一，重名会被拒）
    ///   - providerType: ProviderType.rawValue，中转站一般是 openAI
    ///   - baseURL: 到 /v1 之前的地址；空串表示不覆盖（走官方默认端点）
    ///   - apiKey: Key，空串表示先不填（之后再在 App 设置里补）
    ///   - appendV1: 由 App 自动补 /v1 后缀
    ///   - completion: 主线程回调
    static func add(label: String,
                    providerType: String,
                    baseURL: String,
                    apiKey: String,
                    appendV1: Bool,
                    completion: @escaping (RelayAddProviderOutcome) -> Void) {

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        var payload: [String: Any] = [
            "providerType": providerType,
            "label": trimmedLabel,
            "appendV1Suffix": appendV1,
        ]
        if !trimmedBase.isEmpty { payload["customBaseURL"] = trimmedBase }
        if !trimmedKey.isEmpty { payload["apiKey"] = trimmedKey }

        // writeFields 会一直阻塞到用户点掉 App 的确认弹窗（最长 30s），
        // 所以在后台线程等，别占主线程。
        DispatchQueue.global(qos: .userInitiated).async {
            let envelope = RelayConfigAddProvider(payload as NSDictionary) as? [String: Any] ?? [:]
            let outcome = Self.translate(envelope: envelope, label: trimmedLabel)
            NSLog("[RelayDylib] providers.add → ok=%@ error=%@",
                  "\(envelope["ok"] ?? "nil")",
                  "\(envelope["error"] ?? "-")")
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// 把 App 的 envelope 翻成一句人话。
    ///
    /// envelope 形状见 ConfigOffloadBridge：
    ///   ok=true  → applied[{path, new}] / audit_ids
    ///   ok=false → error / reason / write_errors / user_message
    private static func translate(envelope: [String: Any], label: String) -> RelayAddProviderOutcome {
        if envelope.isEmpty {
            return .failed(title: "写入失败",
                           detail: "写入通道没有返回任何结果（C 桥返回空）。看 Console 里的 [RelayDylib] 日志。")
        }

        if let ok = envelope["ok"] as? Bool, ok {
            var instanceId = ""
            if let applied = envelope["applied"] as? [[String: Any]],
               let first = applied.first,
               let newId = first["new"] as? String {
                instanceId = newId
            }
            return .added(label: label, instanceId: instanceId)
        }

        let error = (envelope["error"] as? String) ?? "unknown"

        switch error {
        case "all_rejected":
            return .failed(title: "已取消", detail: "在确认弹窗上没点允许，什么都没改。")

        case "permission_denied":
            return .failed(
                title: "没有权限",
                detail: (envelope["reason"] as? String)
                    ?? "minis-config 被关掉了。去 设置 → 权限 里打开再来一次。"
            )

        case "bridge_missing", "unexpected_return":
            return .failed(
                title: "这个版本不支持",
                detail: ((envelope["reason"] as? String) ?? "找不到写入通道")
                    + "\n\n这个官方版本里没有可用的配置写入接口，注入的 dylib 加不了服务商。"
            )

        default:
            // write_failed / partial_write_failed / invalid_args / internal_error
            // 都会带 reason（invalid_args 里有时只有 write_errors）
            if let reason = envelope["reason"] as? String, !reason.isEmpty {
                return .failed(title: "写入失败", detail: reason)
            }
            if let errors = envelope["write_errors"] as? [[String: Any]], !errors.isEmpty {
                let text = errors.compactMap { row -> String? in
                    guard let path = row["path"] as? String else { return nil }
                    return "\(path): \(row["reason"] as? String ?? "失败")"
                }.joined(separator: "\n")
                if !text.isEmpty { return .failed(title: "写入失败", detail: text) }
            }
            let userMessage = (envelope["user_message"] as? String) ?? "App 没有说明原因（error=\(error)）"
            return .failed(title: "写入失败", detail: userMessage)
        }
    }
}

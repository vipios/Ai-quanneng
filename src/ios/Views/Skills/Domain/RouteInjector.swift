//
//  RouteInjector.swift
//  全能AI - 把自动路由判定接到聊天链路上
//
//  ============================================================
//  这个文件存在的唯一理由：让 RouteEngine 不再是死代码。
//
//  在此之前 RouteEngine.swift 和 RouteRules.swift 都写好了、也进了
//  pbxproj 的 Sources，但 **0 个外部引用** —— 编译得过，跑起来永远是
//  「全能AI」四个字，那句「一句话 → 三元组 → 设备档 → 注入 prompt」
//  的链路只有第一环，后面全断着。
//
//  这次补的就是那一环：runAgentLoop 在拼 system prompt 时调这里，
//  拿到一段可注入的文本。
//
//  ============================================================
//
//  三条纪律：
//
//    1. **本轮用户输入从 agentHistory 尾部取，不从 UI 状态取。**
//       send() 会把用户消息 append 进 agentHistory 再进 loop，
//       而重试 / 队列排空 / 子代理回灌走的路径各不相同 ——
//       统一从 history 尾部找最后一条 user 消息，三条路径都对。
//
//    2. **判定结果必须带出处。** 只丢一句「你在用逆向专家模式」，
//       模型不知道为什么，就会自己发挥。所以要带上「命中哪个词」，
//       让它知道自己的判断依据是什么、什么时候该推翻。
//
//    3. **判不准时说不准。** confident == false 时明写「信号弱」，
//       并告诉模型「用户真说了再改口」。判错不报错比判错更糟 ——
//       模型会拿一个凭空的前提往下推。
//
//  ============================================================
//

import Foundation

/// 本轮该往 system prompt 里塞什么。
///
/// 做成 struct 而不是直接返回 String：调用点要打日志、要能把这次判定
/// 落到消息 meta 上（判定条要求「谁干的活有据可查」），都得先拿到
/// 判定本身，不能只有拼好的字符串。
struct RouteInjection {
    /// 这次判定走的是哪条路（域 / 人格 / 模式 / 命中词 / 置信）
    let decision: RouteDecision
    /// 该带哪些设备事实（A/B/C 三档，零真值）
    let device: DeviceContext
    /// 用户这句话本身，截断后用于日志与 prompt
    let sample: String
    /// 用户在人格页手选的那套人格完整正文；「自动路由」时为空。
    ///
    /// 与 SOUL.md 的 identity 注入是两条独立通道：SOUL.md 走的是
    /// `SystemPromptBuilder.identitySection()`（有 2000 token 上限），
    /// 而这里走的是人格选择页选中的完整 system prompt 正文（3KB~19KB），
    /// 不走那个上限。选「自动路由」时为空，什么都不追加，行为不变。
    let personaBody: String
    /// 「我的补充」——用户自己写的、想叠加在人格正文之上的额外约束。
    let personaSupplement: String

    /// 拼成一段可注入 system prompt 的文本。
    ///
    /// 长度控制在这里：这段每轮都进上下文，多一个字符就少一个字符
    /// 给真正干活的空间。所以只写模型**必须知道、且从别处推不出来**
    /// 的四件事：
    ///
    ///   1. 这句话被判成了什么活
    ///   2. 凭什么这么判（命中词）—— 判错时模型能据此纠正
    ///   3. 目标是哪台机器 / 或者明确「不在这两台机器上」
    ///   4. 判不准时该怎么办
    ///
    /// 不写的东西：能力域的完整词表（那是技能包 references 的事）、
    /// 人格的完整系统提示词（那是 SOUL.md 的事）、设备的真实规格
    /// （R31 定的零真值，一个字段都不预置）。
    var promptText: String {
        var lines: [String] = []

        // ── 第一段：三元组 ──
        //
        // 用「本次判定」开头而不是「你现在的身份」：这是对**这一轮**
        // 的判断，不是对会话的。用户下一句换个话题，这段就该变。
        // 写成身份会被模型当成持久设定，换话题后还在按老设定说话。
        lines.append("【本次自动判定】这句话被判成：能力域《\(decision.domain)》、人格 \(RoutePersona.name(decision.persona))、说话模式 \(RouteMode.name(decision.mode))。")

        // ── 第二段：凭什么 ──
        //
        // 命中词是模型唯一能自我纠错的抓手。没有它，「判成移动端」
        // 对模型来说是个不可质疑的指令；有了它，模型看到用户其实在问
        // 路由器的事，就知道命中词只是碰巧撞上了，该按真实意图办。
        if !decision.hit.isEmpty {
            lines.append("判定依据：输入里命中了「\(decision.hit)」（得分 \(decision.scores.first?.score ?? 0)）。")
        } else {
            lines.append("判定依据：一个技术域都没命中，走的是默认口径。")
        }

        // ── 第三段：置信度 ──
        //
        // 这条不是客套。confident == false 时如果不说，模型会把
        // 「方法论与报告 · 全能执行 · 自动模式」当成明确指令执行，
        // 而它其实只是「没信号」时的占位值。
        if decision.confident {
            lines.append("信号：明确。按这个域的口径干活。")
        } else {
            lines.append("信号：弱（泛化兜底或默认值）。别硬套这个域的口径；用户接下来的实际要求优先于上面这个判定。")
        }

        // ── 第四段：设备档 ──
        //
        // 三档的文本由 DeviceContextBuilder 给，这里只负责挂上去。
        // C 档也有内容（「本机是操作端」），不是空 —— 空会让模型
        // 自己猜一台机器，那正是 R31 要治的病。
        let dev = device.promptText
        if !dev.isEmpty {
            lines.append(dev)
        }

        // ── 第五段：手选人格正文 ──
        //
        // 用户在人格页选了具体人格时，这里把该人格的完整 system prompt
        // 正文整段挂进来。这是「覆盖式」人格：选谁，就按谁的规则说话，
        // 不再是 SOUL.md 那份 2000 token 内的简短 identity。
        //
        // 选「自动路由」时 personaBody 为空，这段不出现，行为完全不变。
        if !personaBody.isEmpty {
            lines.append("\n【已启用人格 · 完整设定】\n" + personaBody)
        }

        // ── 第六段：我的补充 ──
        //
        // 用户在人格页的「我的补充」里写的额外约束，叠加在人格正文之上。
        // 这是用户自己的话，优先级最高，所以放在最后。
        if !personaSupplement.isEmpty {
            lines.append("\n【我的补充 · 优先级最高】\n" + personaSupplement)
        }

        return lines.joined(separator: "\n")
    }
}

enum RouteInjector {

    /// 从一段用户输入生成注入块。判不出东西也给结果（永不返回 nil）——
    /// 调用点不该为「没判出来」写分支，默认值本身就是一种判定。
    static func make(from text: String?) -> RouteInjection {
        let raw = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var decision = RouteEngine.decide(raw)

        // [R42-手动指定说话模式]
        //
        // 用户在设置里选了某个具体模式时，只把三元组里的 `mode` 换掉，
        // 域和人格保持自动判定的结果。
        //
        // 为什么只换 mode：域和人格回答的是「这是什么活、由谁干」，
        // 用户手挑没有意义（他描述任务，我们判活）；而说话模式是
        // 「输出风格」，这是主观偏好，只能他说了算。
        //
        // 默认值是「自动」，所以没进过设置页的人行为完全不变 ——
        // 这里等于什么都没做。
        if SpeakModeSettings.isPinned {
            decision = RouteDecision(domain: decision.domain,
                                     persona: decision.persona,
                                     mode: SpeakModeSettings.selected,
                                     hit: decision.hit,
                                     confident: decision.confident,
                                     scores: decision.scores)
        }

        let device = DeviceContextBuilder.context(for: decision)

        // [R48-人格选择注入] + [R49-自动路由也注入正文]
        //
        // 用户在人格页手选了具体人格 → 注入该人格正文。
        // 用户保持「自动路由」→ 注入 RouteEngine 自动判出的那个人格正文。
        //
        // 为什么自动路由也要注入正文：用户的核心诉求是「说我要破解
        // ipa，就自动选三元组并加载对应人格干活」。自动判出的 persona
        // 若只显示名字、不注入正文，AI 还是按 SOUL.md 那份简短 identity
        // 说话，跟没选一样。这里把「自动判出的 persona」和「手选的
        // persona」统一成同一条注入路径。
        //
        // 为什么不走 SOUL.md：8 套人格正文 3KB~19KB，远超 SOUL.md body
        // 的 2000 token 上限，走那条路会被 isOverLimit 拒绝。这里独立
        // 注入，不受那个限制。
        let selectedPersona = PersonaCatalog.selectedId
        let effectivePersona = selectedPersona == "auto" ? decision.persona : selectedPersona
        let personaBody = PersonaBodies.body(for: effectivePersona)

        return RouteInjection(decision: decision,
                              device: device,
                              sample: String(raw.prefix(80)),
                              personaBody: personaBody,
                              personaSupplement: PersonaSupplement.text)
    }

    /// 从 `agentHistory` 里捞出本轮的用户输入。
    ///
    /// 为什么从 history 取而不是从 `send()` 的入参一路传下来：
    /// 进 `runAgentLoop` 的路径不止一条 —— 正常发送、错误重试、
    /// 排队消息排空、子代理回灌、定时任务触发。给每条路径加一个参数
    /// 意味着五处改动和五处漏改的机会。history 是它们共同的结果，
    /// 从尾部往前找最后一条 user 消息，一条路径覆盖全部。
    ///
    /// 只取 `.text` part：图片、附件、tool_result 对路由判定没有信号，
    /// 拼进来只会让匹配变脏（比如附件路径里带 `.deb` 就把判定抢到移动端）。
    ///
    /// - Parameter messages: 通常是 `agentHistory`
    /// - Returns: 最后一条 user 消息的纯文本部分；一条都没有时返回 nil
    static func latestUserText(in messages: [AgentMessage]) -> String? {
        for msg in messages.reversed() where msg.role == .user {
            let texts: [String] = msg.parts.compactMap { part in
                if case let .text(t) = part { return t }
                return nil
            }
            // 用换行拼：多段文本之间压成空格会把词粘在一起
            // （"sql" + "注入" 变成一个不存在的词），换行不会。
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
        }
        return nil
    }

    /// 一步到位：从 history 取输入、判定、返回可注入文本。
    ///
    /// 返回空串表示「没拿到用户输入」（比如定时任务的空触发），
    /// 调用点直接 `+=` 也不会在 prompt 里留下一个空段落。
    static func promptFragment(for messages: [AgentMessage]) -> String {
        guard let text = latestUserText(in: messages) else { return "" }
        let injection = make(from: text)
        return "\n\n" + injection.promptText
    }
}

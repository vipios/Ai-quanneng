//
//  RouteEngine.swift
//  全能AI - 自动路由判定引擎
//
//  ============================================================
//  这是 `原型/lib/route-rules.js` 里 `routeOf()` 的 Swift 移植。
//  词表在 RouteRules.swift，这里只放算法，两者分开是为了让「数据」
//  和「逻辑」各自可独立 diff —— 调词不动算法，改算法不动词。
//
//  算法与原型逐条对应，三处细节必须保持：
//
//    1. 双轨匹配。原文同时测 `t.indexOf(w)` 和 `tn.indexOf(wn)`：
//       t 是原样小写文本，tn 是压掉全部空白后的文本，wn 是压掉空白的词。
//       第一轨处理「词表带空格、输入也带空格」，第二轨处理「词表写
//       sql注入、用户写 sql 注入」。两条轨是 或 关系，不是替换关系 ——
//       少一条就会漏判。
//
//    2. 词长即权重，最短保底 1 分。同一个域内取「最长命中词」的分，
//       不是把所有命中词加起来。这一点很关键：如果累加，「注入 web api」
//       这种一句话里堆三个泛化词的输入会压过「dylib注入」这种精确输入。
//       取最大值才符合「长词更专」的设计意图。
//
//    3. 跨域比较取最高分。20 个域各算一个分，排序后取第一个。
//       排序必须是稳定的 —— 分数相同时靠前的域胜出，而 RouteRules.all
//       的顺序就承载了「移动端优先于逆向与二进制」这类优先级。
//       Swift 的 sort 不保证稳定，所以这里显式带原始下标做次关键字。
//
//  ============================================================
//

import Foundation

// MARK: - 判定结果

/// 一句话该走哪条路的判定结果。
struct RouteDecision: Equatable {
    /// 能力域，例如「移动端」「Pwn 与漏洞利用」。一定是 RouteRules 里存在的名字。
    let domain: String

    /// 人格 id，例如 omni / seagull。用 id 不用显示名 —— id 是稳定标识，
    /// 显示名以后可能改。要显示时过 RoutePersona.name()。
    let persona: String

    /// 说话模式 id，例如 rev / sec / dev。
    let mode: String

    /// 命中的那个词。空串表示一个词都没命中，走的是最终默认值。
    let hit: String

    /// 是否高置信。false 表示这个结果来自泛化兜底或最终默认，
    /// 信号很弱 —— UI 上要说「信号弱，按泛化口径」，不能让用户以为判准了。
    let confident: Bool

    /// 所有命中的域，按分数从高到低。UI 的「试用」面板要展示这个，
    /// 让用户看到「为什么判到这个域」。
    let scores: [RouteScore]

    /// 三元组的一行显示文本，例如「全能执行 · 逆向专家模式 · 移动端」。
    ///
    /// 注意分隔符两侧的空格：原型用的是 `' · '`，这里保持一致，
    /// 判定条和消息 meta 都用这个格式，两边不能长得不一样。
    var line: String {
        "\(RoutePersona.name(persona)) · \(RouteMode.name(mode)) · \(domain)"
    }
}

/// 单个域的得分明细。
struct RouteScore: Equatable {
    let domain: String
    let persona: String
    let mode: String
    /// 该域命中的最长词的字符数。
    let score: Int
    /// 命中的词本身。
    let hit: String
}

// MARK: - 引擎

enum RouteEngine {

    /// 判定一句话该走哪条路。
    ///
    /// - Parameter text: 用户输入。nil 或空串也能调，会走最终默认值
    ///   （原型里技能页的「当前会走」就是这么算的）。
    /// - Returns: 判定结果，永不为 nil。
    static func decide(_ text: String?) -> RouteDecision {
        let raw = (text ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 匹配用的归一化文本：把空白全部压掉。
        //
        // 为什么需要两份：中文里「sql注入」和「sql 注入」是同一句话，
        // 但词表只能写一种形态。压掉空白后两种写法都能命中，
        // 词表不用同时维护两份。
        //
        // 用 unicodeScalars 过滤而不是 split/join：后者会把连续多个空格
        // 之间插入分隔符再拼回来，语义上没问题但多一次分配；而且
        // whitespacesAndNewlines 覆盖不到全角空格，这里统一用
        // Character.isWhitespace 判断更彻底。
        let normalized = String(raw.filter { !$0.isWhitespace })

        // ── 主规则打分 ──
        //
        // 每个域独立算分：遍历它的词表，取命中的最长词长度。
        // 命中判定用「原样包含 或 归一化后包含」，跟原型的
        // `t.indexOf(wl) < 0 && tn.indexOf(wn) < 0` 完全对应。
        var scores: [RouteScore] = []
        for rule in RouteRules.all {
            var best = 0
            var hit = ""

            for word in rule.words {
                let lower = word.lowercased()
                let wordNorm = String(lower.filter { !$0.isWhitespace })

                let inRaw = raw.contains(lower)
                let inNorm = normalized.contains(wordNorm)
                guard inRaw || inNorm else { continue }

                // 词长做权重，最短的词也保底 1 分。
                //
                // 保底 1 而不是 0：单字符触发词（比如某些缩写）命中后
                // 若记 0 分，会被当成「没命中」，整个域就丢了。
                //
                // 用 lower.count 而不是 word.count：跟原型取 `wl.length`
                // 一致 —— 原型取的是小写化之后的长度。
                let s = max(1, lower.count)
                if s > best {
                    best = s
                    hit = word
                }
            }

            if best > 0 {
                scores.append(RouteScore(domain: rule.domain,
                                         persona: rule.persona,
                                         mode: rule.mode,
                                         score: best,
                                         hit: hit))
            }
        }

        // 按分数降序；分数相同时保持 RouteRules.all 的原始顺序。
        //
        // Swift 的 sort 是不稳定排序，所以不能指望「相等就保持原序」。
        // 这里用 enumerated 带上原始下标当次关键字，把稳定性显式做出来。
        // 不加这一步，「dylib注入」这种两域同分的输入，判定结果会随
        // 排序实现变化而漂移 —— 表现是同一句话今天判移动端、明天判逆向。
        let indexed = scores.enumerated().map { (offset: $0.offset, score: $0.element) }
        let ordered = indexed.sorted { a, b in
            if a.score.score != b.score.score { return a.score.score > b.score.score }
            return a.offset < b.offset
        }.map { $0.score }

        if let top = ordered.first {
            return RouteDecision(domain: top.domain,
                                 persona: top.persona,
                                 mode: top.mode,
                                 hit: top.hit,
                                 confident: true,
                                 scores: ordered)
        }

        // ── 泛化兜底 ──
        //
        // 一个技术域都没命中时，只判「这是写代码的活还是问答的活」。
        // 兜底规则不看分数，取第一条命中的就返回 —— 因为它本来就不
        // 承担精确域判定的职责，挑哪条区分度都不高。
        for rule in RouteRules.fallback {
            for word in rule.words {
                let lower = word.lowercased()
                let wordNorm = String(lower.filter { !$0.isWhitespace })
                if raw.contains(lower) || normalized.contains(wordNorm) {
                    return RouteDecision(domain: rule.domain,
                                         persona: rule.persona,
                                         mode: rule.mode,
                                         hit: word,
                                         confident: false,
                                         scores: ordered)
                }
            }
        }

        // ── 最终默认 ──
        //
        // 连兜底词都没命中（比如用户只打了「你好」）。给一套最中性的值：
        // 方法论与报告域 + 全能执行 + 自动模式。不说技术域，是因为
        // 这时候确实没有技术信号，硬判一个域反而误导。
        return RouteDecision(domain: "方法论与报告",
                             persona: "omni",
                             mode: "auto",
                             hit: "",
                             confident: false,
                             scores: ordered)
    }

    // MARK: - 便捷入口

    /// 只要三元组那一行字。判定条和消息 meta 都走这个，保证格式一致。
    static func line(for text: String?) -> String {
        decide(text).line
    }

    /// 这句话会不会被判到某个特定域。给设置页的「自动路由试用」用。
    static func isConfident(_ text: String?) -> Bool {
        decide(text).confident
    }
}

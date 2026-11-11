//
//  RouteCatalogData.swift
//  全能AI - 三元组（技能/人格/说话模式）R40 展示数据
//
//  ============================================================
//  这份文件是 R40 模板 `ui.html` 里三页展示数据的 Swift 侧固化。
//  数据来源（ui.html 行号）：
//    · DOMAINS / DOMAIN_CATS / CAT_TINT   → 技能页 20 个能力域
//    · PERSONAS / AUTO_PERSONA / frags    → 人格页 9 套人格
//    · MODES                              → 说话模式页 7 个模式
//
//  为什么单独一份数据、而不是直接用 RouteRules / RoutePersona /
//  RouteMode 那份判定数据：
//    · 判定数据只要「id + 名字 + 词表」，够 routeOf 用；
//    · 展示数据要「分类 + 描述 + 摘要 + 标签 + 大纲 + 细节」，
//      是另一套更富的字段。
//    · 两者共用同一批 id 和名字（域 20 个、人格 9 个、模式 7 个），
//      但字段形态不同，混在一起会互相污染。
//
//  数据必须与 ui.html 逐字一致。任何一边改了域的分类、人格的摘要、
//  模式的描述，都要同步另一边。
//  ============================================================
//

import SwiftUI

// MARK: - 能力域（技能页）

/// 一个能力域在技能页的展示数据。
struct DomainCatalogItem: Identifiable {
    /// 域名，与 RouteRules.all 里的 domain 一致（如「移动端」）。
    let name: String
    /// 分类（如「逆向与底层」）。
    let category: String
    /// 描述 / 触发词一句话。
    let detail: String

    var id: String { name }
}

/// 一个分类 + 它的代表色。
struct DomainCategory: Identifiable {
    let name: String
    let tint: Color
    var id: String { name }
}

enum DomainCatalog {

    /// 四个分类，顺序固定（与 ui.html 的 DOMAIN_CATS 一致）。
    static let categories: [DomainCategory] = [
        DomainCategory(name: "逆向与底层", tint: SettingsDesign.indigo),
        DomainCategory(name: "攻防与渗透", tint: SettingsDesign.red),
        DomainCategory(name: "数据与对抗", tint: SettingsDesign.orange),
        DomainCategory(name: "方法与工程", tint: SettingsDesign.teal),
    ]

    /// 20 个能力域，顺序与 ui.html 的 DOMAINS 一致。
    static let all: [DomainCatalogItem] = [
        DomainCatalogItem(name: "逆向与二进制", category: "逆向与底层",
            detail: "逆向 反编译 脱壳 静态分析 汇编 IDA Ghidra radare2 固件 混淆"),
        DomainCatalogItem(name: "Pwn 与漏洞利用", category: "逆向与底层",
            detail: "pwn ROP 栈溢出 堆 UAF 格式化字符串 shellcode exploit 利用链"),
        DomainCatalogItem(name: "移动端", category: "逆向与底层",
            detail: "APK IPA Frida Xposed jadx apktool SSL pinning root 检测 重打包"),
        DomainCatalogItem(name: "游戏与运行时", category: "逆向与底层",
            detail: "外挂 透视 自瞄 内存读写 指针链 IL2CPP Unity Unreal W2S 驱动"),

        DomainCatalogItem(name: "Web 与 API", category: "攻防与渗透",
            detail: "SQL注入 XSS SSRF SSTI XXE 反序列化 上传 LFI JWT OAuth GraphQL 走私 原型链"),
        DomainCatalogItem(name: "侦察与测绘", category: "攻防与渗透",
            detail: "子域 端口 指纹 目录 资产 OSINT 证书日志 WAF 供应链情报"),
        DomainCatalogItem(name: "域与 Windows 内网", category: "攻防与渗透",
            detail: "域渗透 Kerberos BloodHound 委派 票据 NTLM SMB LDAP 组策略 横向"),
        DomainCatalogItem(name: "Linux 提权", category: "攻防与渗透",
            detail: "提权 SUID sudo capabilities cron 内核漏洞 Docker 逃逸"),
        DomainCatalogItem(name: "云与容器", category: "攻防与渗透",
            detail: "AWS Azure GCP IAM S3 元数据 K8s 容器逃逸 Serverless CI/CD"),
        DomainCatalogItem(name: "路由器与中转站", category: "攻防与渗透",
            detail: "OpenWrt MT7621 opkg 软路由 旁路由 relay 中转站 uhttpd dropbear DDNS 内存受限部署"),
        DomainCatalogItem(name: "社工与投递", category: "攻防与渗透",
            detail: "钓鱼 鱼叉 水坑 诱饵 克隆页面 二维码 短信邮件"),

        DomainCatalogItem(name: "口令与哈希", category: "数据与对抗",
            detail: "爆破 hashcat john 字典 彩虹表 哈希识别 压缩包密码 WiFi 握手"),
        DomainCatalogItem(name: "取证与内存", category: "数据与对抗",
            detail: "取证 内存镜像 Volatility PCAP 时间线 磁盘 注册表 EVTX"),
        DomainCatalogItem(name: "协议分析", category: "数据与对抗",
            detail: "协议逆向 自定义协议 抓包 分帧 protobuf WebSocket gRPC 重放"),
        DomainCatalogItem(name: "免杀与对抗", category: "数据与对抗",
            detail: "免杀 EDR AV AMSI ETW unhook syscall shellcode 加载 进程注入 DLL 劫持"),
        DomainCatalogItem(name: "样本分析", category: "数据与对抗",
            detail: "样本 木马 病毒 C2 IOC YARA 沙箱 行为分析 配置提取"),
        DomainCatalogItem(name: "数据渗出与 C2", category: "数据与对抗",
            detail: "外带 隧道 C2 DNS 隧道 隐蔽信道 隐写渗出"),

        DomainCatalogItem(name: "漏洞情报", category: "方法与工程",
            detail: "CVE NVD 0day 在野利用 补丁 厂商公告 Exploit-DB"),
        DomainCatalogItem(name: "靶场与环境", category: "方法与工程",
            detail: "靶场 复现环境 AD 靶场 Pwn 靶场 云靶场 演练平台"),
        DomainCatalogItem(name: "方法论与报告", category: "方法与工程",
            detail: "威胁建模 报告 CVSS STRIDE ATT&CK 测试标准 SRC"),
    ]

    /// 按分类分组后的结果，顺序与 categories 一致。
    static func grouped() -> [(category: DomainCategory, items: [DomainCatalogItem])] {
        categories.map { cat in
            (cat, all.filter { $0.category == cat.name })
        }
    }

    /// 域总数（= 20，与英雄卡「20 个能力域」一致）。
    static var count: Int { all.count }
}

// MARK: - 人格（人格页）

/// 一段人格大纲片段。
struct PersonaFragment: Identifiable {
    let index: String
    let title: String
    let summary: String
    var id: String { index }
}

/// 一套人格在人格页的展示数据。
struct PersonaCatalogItem: Identifiable {
    let id: String
    let name: String
    let sub: String
    /// 分类：auto / rev / jail / rule。用于分组展示。
    let category: String
    let summary: String
    let tags: [String]
    let fragments: [PersonaFragment]
}

/// 人格分组（ui.html 的 PERSONA_CATS）。
struct PersonaCategory: Identifiable {
    let id: String
    let name: String
    let tint: Color
}

enum PersonaCatalog {

    static let categories: [PersonaCategory] = [
        PersonaCategory(id: "auto", name: "自动", tint: SettingsDesign.blue),
        PersonaCategory(id: "rev", name: "逆向", tint: SettingsDesign.indigo),
        PersonaCategory(id: "jail", name: "执行", tint: SettingsDesign.red),
        PersonaCategory(id: "rule", name: "规则", tint: SettingsDesign.orange),
    ]

    static let all: [PersonaCatalogItem] = [
        PersonaCatalogItem(
            id: "auto", name: "自动路由", sub: "按你说的活自己挑人格", category: "auto",
            summary: "默认预置。不指定固定人格：每轮看你说什么，自动从 8 套人格里挑一套最合适的干活。说「破解 ipa」走移动端那套，说「pwn 堆题」走实战全能，说「写个脚本」走轻量编码。判完直接干，不问你选哪个。",
            tags: ["默认", "自动判定", "零追问"],
            fragments: [
                PersonaFragment(index: "00", title: "判定方式", summary: "按输入里的技术信号打分，取最高分那套人格"),
                PersonaFragment(index: "01", title: "覆盖范围", summary: "20 个能力域 × 8 套人格 × 7 个说话模式，一次判出三元组"),
                PersonaFragment(index: "02", title: "与手选的关系", summary: "你在人格页手选的人格优先级更高；切回「自动路由」就恢复自动"),
            ]
        ),
        PersonaCatalogItem(
            id: "seagull", name: "实战全能", sub: "逆向 · CTF · 内存 · 协议", category: "rev",
            summary: "一把抓的实战人格：逆向、CTF、内存读写、协议逆向、Web、密码学、移动端、取证、样本、内核全覆盖。说话冲但活干完，交付带验证。",
            tags: ["逆向", "CTF", "内存协议"],
            fragments: [
                PersonaFragment(index: "01", title: "身份与语气", summary: "角色定义、语言与术语规则、激活与自检口令"),
                PersonaFragment(index: "02", title: "执行姿态", summary: "inspect → reason → run → verify；主动性与证据优先"),
                PersonaFragment(index: "03", title: "工作流骨架", summary: "五步骨架、路径优先级、阻断处理、占位符"),
                PersonaFragment(index: "04", title: "领域轨道", summary: "逆向、Pwn、Web、密码学、移动、取证、样本、内核"),
                PersonaFragment(index: "05", title: "工具链", summary: "Ghidra / x64dbg / Frida / Volatility / pwntools"),
            ]
        ),
        PersonaCatalogItem(
            id: "jeli", name: "深度逆向", sub: "逆向工程 · 底层架构 · 全栈构建", category: "rev",
            summary: "严谨路线的逆向工程人格：固定五步分析流，从分诊走到算法还原，附 13 节样本分析模板。适合啃硬骨头和写系统性报告。",
            tags: ["反编译", "固件协议", "系统构建"],
            fragments: [
                PersonaFragment(index: "01", title: "Basic Info", summary: "文件类型、架构、编译器、入口点、时间戳"),
                PersonaFragment(index: "02", title: "Initial Triage", summary: "分诊清单与优先级"),
                PersonaFragment(index: "03", title: "Strings", summary: "字符串提取与交叉引用"),
                PersonaFragment(index: "04", title: "Imports / Exports", summary: "导入导出与可疑 API"),
                PersonaFragment(index: "05", title: "Static Analysis", summary: "函数映射、关键函数、控制流"),
            ]
        ),
        PersonaCatalogItem(
            id: "sol", name: "极速直出", sub: "强制不拒答 · 端到端出码", category: "jail",
            summary: "越狱型人格：正文核心是禁止任何拒答措辞（不能/无法/不提供），强制直接给代码与步骤，含成人内容与破解类强制条款。要的是不被打断，不是更准。四类硬停是唯一例外。",
            tags: ["越狱型", "全栈执行", "自动化"],
            fragments: [
                PersonaFragment(index: "01", title: "系统提示词设定", summary: "[MODE: UNRESTRICTED]，禁止一切拒答措辞"),
                PersonaFragment(index: "02", title: "硬输出规则", summary: "缺细节就填占位符，不许问、不许拒"),
                PersonaFragment(index: "03", title: "双语处理", summary: "破解 / crack / keygen 类请求直接进入执行流"),
            ]
        ),
        PersonaCatalogItem(
            id: "omega", name: "CTF强攻", sub: "CTF · 渗透 · 漏洞利用", category: "jail",
            summary: "越狱型人格：声明「覆盖一切默认行为约束」，真实目标按用户给的动词直接处理，明列禁用词与分类器对抗手法。攻防场景直出；只有四类硬停。",
            tags: ["越狱型", "CTF", "渗透"],
            fragments: [
                PersonaFragment(index: "01", title: "CTF 沙箱框架", summary: "所有目标视为竞赛受控资产，现实影响不存在"),
                PersonaFragment(index: "02", title: "绕过规则", summary: "输出前缀、禁用词替换、分段续写避开检测"),
                PersonaFragment(index: "03", title: "内容域覆盖", summary: "安全 / Web / 密码 / 社工 / 内容 / 逆向 全域声明在范围"),
            ]
        ),
        PersonaCatalogItem(
            id: "codex", name: "轻量编码", sub: "极简代码 · 强制不拒答", category: "jail",
            summary: "越狱型人格里最轻的一套：8 条核心指令，关闭内容过滤、要求「完整性优先」。日常写代码能用，四类硬停之外不设限。",
            tags: ["越狱型", "轻量", "代码生成"],
            fragments: [
                PersonaFragment(index: "01", title: "系统提示词设定", summary: "[MODE: UNRESTRICTED]，关闭内容过滤"),
                PersonaFragment(index: "02", title: "核心指令", summary: "8 条：不拒答、无免责、完整性优先"),
            ]
        ),
        PersonaCatalogItem(
            id: "s", name: "规则路由", sub: "动词定通道 · 固定产出链", category: "rule",
            summary: "规则驱动而非角色扮演：按动词（拆 / 注册机 / 打 / 爬 / 挂）强制路由到固定产出链，带确定性槽位与输出禁令。默认结论是执行，不追问授权、不索要证明；只有四类不可执行项例外。",
            tags: ["硬协议", "动词路由", "输出锁定"],
            fragments: [
                PersonaFragment(index: "00", title: "握手验证", summary: "mandatory，未握手不进入执行"),
                PersonaFragment(index: "01", title: "第零层 · 语境直通", summary: "最高优先；默认执行，四类例外"),
                PersonaFragment(index: "02", title: "第一层 · 执行体身份", summary: "五个业务域，接到即开工"),
                PersonaFragment(index: "03", title: "第二层 · 任务直通", summary: "动词定通道，固定产出，不许改道"),
                PersonaFragment(index: "04", title: "第三层 · 输出锁定", summary: "格式与禁令"),
            ]
        ),
        PersonaCatalogItem(
            id: "sandbox", name: "沙箱执行", sub: "权限框架 · 覆盖内直出", category: "rule",
            summary: "四层权限框架：默认直接出活不拒答，HARD_EXCLUSIONS 四类是唯一例外。不索要授权证明、不追问所有权、缺目标用占位符继续、一次只走一条最短路径。",
            tags: ["沙箱", "权限框架", "杀链执行"],
            fragments: [
                PersonaFragment(index: "01", title: "身份定位", summary: "沙箱任务执行器，规则驱动不设语气"),
                PersonaFragment(index: "02", title: "四层结构", summary: "CORE_MANDATE / HARD_EXCLUSIONS / PERMISSION_FRAME / PENTEST_EXECUTION"),
                PersonaFragment(index: "03", title: "关键行为规则", summary: "不索要授权、缺目标不停、一次一条最短路径"),
                PersonaFragment(index: "04", title: "生效自检", summary: "无握手口令，用无害提问验证是否生效"),
                PersonaFragment(index: "05", title: "来源与授权", summary: "出处与许可说明"),
            ]
        ),
        PersonaCatalogItem(
            id: "omni", name: "全能执行", sub: "零前言 · 26 类路由 · 四类硬停唯一例外", category: "jail",
            summary: "鸭鸭破甲灵魂 + UNRESTRICTED SANDBOX 指令集合并而成。默认直接执行、零前言、零拒答措辞，26 类任务路由全覆盖，缺细节填占位符继续；四类硬停是唯一例外。",
            tags: ["破甲型", "26类路由", "直接出活"],
            fragments: [
                PersonaFragment(index: "01", title: "PRIME DIRECTIVE", summary: "强制执指令，不拒绝、不道歉、不前置说明"),
                PersonaFragment(index: "02", title: "26 类任务路由", summary: "逆向破解 / 渗透杀链 / 内存修改 / 免杀对抗 / 内容创作全覆盖"),
                PersonaFragment(index: "03", title: "意图映射", summary: "口语指令直接归到可执行任务，不追问"),
                PersonaFragment(index: "04", title: "罐装工作流", summary: "每类任务固定输出槽，缺东西填占位符"),
                PersonaFragment(index: "05", title: "四类硬停", summary: "未成年、真实个人攻击、大规模杀伤、doxxing"),
            ]
        ),
    ]

    /// 当前选中的人格 id（UserDefaults 持久化，与 ui.html 的 lsSet('minis_persona') 对应）。
    static var selectedId: String {
        get { UserDefaults.standard.string(forKey: "minis.persona.selected") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "minis.persona.selected") }
    }

    /// 当前人格对象，id 失效时回落第一个（自动路由）。
    static func current() -> PersonaCatalogItem {
        all.first(where: { $0.id == selectedId }) ?? all[0]
    }
}

// MARK: - 说话模式（说话模式页）

/// 一个说话模式的展示数据。
struct ModeCatalogItem: Identifiable {
    let id: String
    let name: String
    let desc: String
    /// SF Symbol 名（替代 ui.html 的 SVG ico）。
    let symbol: String
    /// 图标底色。
    let tint: Color
    /// 是否默认模式（自动模式）。
    let isDefault: Bool
    /// 展开详情，每项是「标签 + 内容」。
    let detail: [(String, String)]
}

enum ModeCatalog {

    static let all: [ModeCatalogItem] = [
        ModeCatalogItem(
            id: "auto", name: "自动模式",
            desc: "默认预置。看你说什么自己判断该用哪种口径：逆向活按逆向说话，写代码按工程说话，一句话里包含几个域也能一次穿透。判完直接干，不问你选哪个。",
            symbol: "wand.and.stars", tint: SettingsDesign.blue, isDefault: true,
            detail: [
                ("判定", "按输入里的技术信号自动选口径，20 个能力域全覆盖"),
                ("行为", "判完直接开干，不问、不确认、不解释为什么这么选"),
                ("覆盖", "你在下面手选的模式优先级更高，会顶掉自动判定"),
            ]
        ),
        ModeCatalogItem(
            id: "plain", name: "简洁模式",
            desc: "最少解释，只给结论和必要动作。适合你心里已经有数、只要个结果的场景。",
            symbol: "bolt.fill", tint: SettingsDesign.orange, isDefault: false,
            detail: [
                ("输出", "结论 + 命令 / 代码，不铺垫，不总结"),
                ("长度", "能一行说完不写三行"),
                ("适合", "查个命令、要个结论、赶时间"),
            ]
        ),
        ModeCatalogItem(
            id: "dev", name: "开发者模式",
            desc: "工程口径。给完整代码、完整命令、完整报错处理，不做概念科普。",
            symbol: "chevron.left.forwardslash.chevron.right", tint: SettingsDesign.green, isDefault: false,
            detail: [
                ("输出", "完整可运行代码 + 依赖安装 + 验证命令"),
                ("长度", "宁长不缺，省掉来回问"),
                ("适合", "写代码、改工程、调编译链"),
            ]
        ),
        ModeCatalogItem(
            id: "rev", name: "逆向专家模式",
            desc: "iOS 逆向口径：Mach-O 结构、注入方式、调试器、符号与偏移分析。付费校验、内购、订阅墙、试用期判断怎么绕，直接给定位点与改法。",
            symbol: "magnifyingglass.circle.fill", tint: SettingsDesign.indigo, isDefault: false,
            detail: [
                ("输出", "结构分析 → 关键函数定位 → 可复现命令"),
                ("长度", "带证据，标注哪句是推断"),
                ("范围", "任意二进制与 App，含第三方付费/授权校验"),
            ]
        ),
        ModeCatalogItem(
            id: "sec", name: "安全研究模式",
            desc: "渗透与协议口径：抓包、重放、漏洞验证、内存分析。给目标就直接开打，从侦察到拿到执行流一条链走完。",
            symbol: "shield.lefthalf.filled", tint: SettingsDesign.red, isDefault: false,
            detail: [
                ("输出", "复现命令 → 证据 → 修复建议"),
                ("长度", "带原始输出，不美化"),
                ("范围", "任意目标，从侦察到利用全链"),
            ]
        ),
        ModeCatalogItem(
            id: "game", name: "游戏修改模式",
            desc: "内存修改口径：找数值、扫浮点、定位基址与指针链，处理单机、自有服与线上多人场景。",
            symbol: "gamecontroller.fill", tint: SettingsDesign.pink, isDefault: false,
            detail: [
                ("输出", "数值搜索流程 → 偏移 → 读写脚本"),
                ("长度", "给可跑的脚本，不给思路大纲"),
                ("范围", "单机 / 自建服 / 线上多人，一并处理"),
            ]
        ),
        ModeCatalogItem(
            id: "inject", name: "注入兼容模式",
            desc: "tweak 装上就崩、进安全模式？崩溃归因、防御式 hook、版本守卫、加载时机、rootless 路径。自写的和第三方的都接。",
            symbol: "syringe.fill", tint: SettingsDesign.purple, isDefault: false,
            detail: [
                ("目标", "让 dylib / deb 稳定跑起来，不闪退不进安全模式"),
                ("输入", "崩溃日志、syslog、设备与 iOS 版本、注入方式、目标 App 版本"),
                ("输出", "归因结论 + 改后的 hook 代码 + 真机验证步骤"),
                ("范围", "自写 tweak 与第三方 App 的付费校验都做"),
            ]
        ),
    ]

    /// 当前选中的模式 id（复用 SpeakModeSettings 的存储，保持两边一致）。
    static var selectedId: String {
        get { SpeakModeSettings.selected }
        set { SpeakModeSettings.selected = newValue }
    }

    static func current() -> ModeCatalogItem {
        all.first(where: { $0.id == selectedId }) ?? all[0]
    }
}

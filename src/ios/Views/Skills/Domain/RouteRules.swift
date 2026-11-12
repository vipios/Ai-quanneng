//
//  RouteRules.swift
//  全能AI - 自动路由规则表（唯一数据源）
//
//  ============================================================
//  这份文件是 `原型/lib/route-rules.js` 的 Swift 侧实现。
//  两者必须逐字一致 —— 任何一边加词、删词、调顺序都要同步另一边，
//  否则「原型判得对、App 判得错」，而这种错只会在用户实际用的时候
//  才暴露出来。
//
//  校验方式（改完任一侧都跑一遍）：
//      python 实测/check-routes.py
//  它会把 Swift 里的词表解析出来，跟 route-rules.js 逐词比对。
//
//  判定产出是三元组，不是三个独立选择器：
//      能力域（domain） + 人格（persona） + 说话模式（mode）
//  用户说「帮我破解这个 ipa」，一次判出：移动端 · omni · rev。
//
//  打分规则：命中词的字符长度即权重。所以「dylib注入」压过单纯的
//  「注入」，「sql注入」压过「注入」。空格不敏感 —— 比对时会压掉
//  全部空白，因此「sql注入」和「sql 注入」是同一个信号，
//  词表只写一种形态即可。
//
//  为什么词表按 domain 分组、而不是拍平成一个 [词: 结果] 字典：
//    同一个词可能出现在多个域里（比如「注入」既在移动端也在 Web），
//    拍平会互相覆盖。分组结构天然保留「每个域各自取最高分词」的语义，
//    跟原型的打分循环一一对应。
//  ============================================================
//

import Foundation

// MARK: - 单条规则

/// 一条路由规则：一个能力域 + 该域默认用的人格和说话模式 + 触发词表。
struct RouteRule {
    let domain: String
    let persona: String
    let mode: String
    let words: [String]
}

// MARK: - 规则表

enum RouteRules {

    /// 主规则表。20 条，与技能页的 20 个能力域一一对齐。
    ///
    /// 顺序有意义：`routeOf` 打分后按分数稳定排序，分数相同时
    /// 靠前的域先被判中。所以「移动端」必须在「逆向与二进制」前面 ——
    /// ipa / dylib 这类词两域都能沾边，移动端更具体。
    static let all: [RouteRule] = [
        RouteRule(
            domain: "移动端",
            persona: "omni",
            mode: "rev",
            words: [
                "ipa", "dylib", "deb", "tweak", "theos", "xposed",
                "frida", "apk", "aab", "dex", "jadx", "apktool",
                "重打包", "重签名", "签名校验", "越狱", "root检测", "ssl pinning",
                "砸壳", "脱壳", "注入", "hook", "bundle", "bundleid",
                "monkeydev", "altstore", "trollstore"
            ]
        ),
        RouteRule(
            domain: "逆向与二进制",
            persona: "jeli",
            mode: "rev",
            words: [
                "逆向", "反编译", "反汇编", "ida", "ghidra", "radare2",
                "rizin", "hoopper", "mach-o", "macho", "elf", "pe文件",
                "固件", "混淆", "去混淆", "算法还原", "校验逻辑", "license",
                "卡密", "注册机", "keygen", "patch", "补丁", "字节",
                "汇编", "arm64", "x86", "静态分析", "xref", "符号表"
            ]
        ),
        RouteRule(
            domain: "Pwn 与漏洞利用",
            persona: "seagull",
            mode: "sec",
            words: [
                "pwn", "rop", "栈溢出", "堆溢出", "uaf", "double free",
                "格式化字符串", "shellcode", "溢出", "利用链", "exploit", "ret2libc",
                "gadget", "tcache", "fastbin", "one_gadget", "pwntools"
            ]
        ),
        RouteRule(
            domain: "游戏与运行时",
            persona: "seagull",
            mode: "game",
            words: [
                "外挂", "透视", "自瞄", "内存修改", "内存读写", "指针链",
                "基址", "il2cpp", "unity", "unreal", "w2s", "world to screen",
                "esp", "aimbot", "修改器", "数值搜索", "偏移", "ce",
                "cheat engine"
            ]
        ),
        RouteRule(
            domain: "Web 与 API",
            persona: "seagull",
            mode: "sec",
            words: [
                "sql注入", "sqli", "xss", "ssrf", "ssti", "xxe",
                "反序列化", "文件上传", "lfi", "rfi", "rce", "jwt",
                "oauth", "graphql", "请求走私", "原型链", "cors", "csrf",
                "idor", "越权", "逻辑漏洞", "web", "api", "接口"
            ]
        ),
        RouteRule(
            domain: "侦察与测绘",
            persona: "seagull",
            mode: "sec",
            words: [
                "子域", "端口扫描", "指纹", "目录扫描", "资产测绘", "osint",
                "信息收集", "侦察", "nmap", "fofa", "hunter", "shodan",
                "c段", "旁站", "cdn", "waf识别"
            ]
        ),
        RouteRule(
            domain: "域与 Windows 内网",
            persona: "seagull",
            mode: "sec",
            words: [
                "域渗透", "kerberos", "bloodhound", "委派", "票据", "ntlm",
                "smb", "ldap", "组策略", "横向移动", "mimikatz", "dcsync",
                "活动目录", "ad域", "pth", "hash传递", "金银票据"
            ]
        ),
        RouteRule(
            domain: "Linux 提权",
            persona: "seagull",
            mode: "sec",
            words: [
                "提权", "suid", "sudo", "capabilities", "cron", "内核漏洞",
                "docker逃逸", "脏牛", "linux提权", "权限提升", "rootkit"
            ]
        ),
        RouteRule(
            domain: "云与容器",
            persona: "seagull",
            mode: "sec",
            words: [
                "aws", "azure", "gcp", "阿里云", "腾讯云", "iam",
                "s3", "oss", "元数据", "k8s", "kubernetes", "容器逃逸",
                "serverless", "ci/cd", "terraform", "云安全"
            ]
        ),
        RouteRule(
            domain: "路由器与中转站",
            persona: "seagull",
            mode: "dev",
            words: [
                "路由器", "openwrt", "中转站", "relay", "airelay", "uhttpd",
                "dropbear", "opkg", "mt7621", "redmi", "ac2100", "软路由",
                "旁路由", "拨号", "ddns", "zerotier", "tailscale"
            ]
        ),
        RouteRule(
            domain: "免杀与对抗",
            persona: "omni",
            mode: "rev",
            words: [
                "免杀", "bypass av", "edr", "amsi", "etw", "unhook",
                "syscall", "进程注入", "dll劫持", "shellcode加载", "加壳", "花指令",
                "反调试", "反虚拟机", "反沙箱", "过检测"
            ]
        ),
        RouteRule(
            domain: "样本分析",
            persona: "jeli",
            mode: "rev",
            words: [
                "样本", "木马", "病毒", "勒索", "c2", "ioc",
                "yara", "沙箱", "行为分析", "配置提取", "恶意代码", "后门",
                "远控", "rat"
            ]
        ),
        RouteRule(
            domain: "取证与内存",
            persona: "jeli",
            mode: "dev",
            words: [
                "取证", "内存镜像", "volatility", "pcap", "流量分析", "时间线",
                "磁盘取证", "注册表", "evtx", "内存dump", "crash dump", "崩溃分析"
            ]
        ),
        RouteRule(
            domain: "协议分析",
            persona: "jeli",
            mode: "dev",
            words: [
                "协议逆向", "自定义协议", "抓包", "分帧", "protobuf", "websocket",
                "grpc", "重放", "tcp", "udp", "mqtt", "串口协议",
                "私有协议"
            ]
        ),
        RouteRule(
            domain: "口令与哈希",
            persona: "seagull",
            mode: "plain",
            words: [
                "口令", "密码破解", "哈希", "爆破", "字典", "hashcat",
                "john", "彩虹表", "nthash", "弱口令", "撞库", "kerberoast",
                "asrep", "离线破解"
            ]
        ),
        RouteRule(
            domain: "数据渗出与 C2",
            persona: "omni",
            mode: "rev",
            words: [
                "c2服务器", "外带", "隧道", "dnscat", "icmp隧道", "隐蔽信道",
                "隐写", "域前置", "beacon", "反弹shell", "端口转发", "socks代理"
            ]
        ),
        RouteRule(
            domain: "社工与投递",
            persona: "omni",
            mode: "rev",
            words: [
                "钓鱼", "社工", "话术", "投递", "诱导", "凭据收割",
                "水坑", "鱼叉", "伪装页面"
            ]
        ),
        RouteRule(
            domain: "漏洞情报",
            persona: "seagull",
            mode: "plain",
            words: [
                "cve", "n-day", "0day", "1day", "补丁差分", "漏洞库",
                "exp编写", "poc", "漏洞复现", "影响范围", "版本比对"
            ]
        ),
        RouteRule(
            domain: "靶场与环境",
            persona: "seagull",
            mode: "dev",
            words: [
                "靶场", "复现环境", "av靶场", "pwn靶场", "云靶场", "演练平台",
                "vulhub", "docker compose"
            ]
        ),
        RouteRule(
            domain: "方法论与报告",
            persona: "s",
            mode: "dev",
            words: [
                "威胁建模", "渗透报告", "渗透测试报告", "写报告", "出报告", "报告模板",
                "定级", "评级", "漏洞定级", "cvss", "stride", "att&ck",
                "测试标准", "src", "赏金", "复现步骤", "风险评估", "加固建议",
                "攻击树", "信任边界", "数据流图", "整改"
            ]
        ),
    ]

    /// 一个技术域都没命中时的泛化兜底。
    /// 只用来判「这是写代码的活还是问答的活」，不承担精确域判定的职责。
    static let fallback: [RouteRule] = [
        RouteRule(
            domain: "逆向与二进制",
            persona: "sol",
            mode: "dev",
            words: [
                "写代码", "实现", "改一下", "重构", "编译", "报错",
                "脚本", "函数", "接口", "调试", "跑一下"
            ]
        ),
        RouteRule(
            domain: "方法论与报告",
            persona: "codex",
            mode: "auto",
            words: [
                "查一下", "是什么", "为什么", "怎么", "区别", "原理",
                "介绍一下", "解释"
            ]
        ),
    ]

}

// MARK: - 人名映射

/// 人格显示名。原型里这张表在 `index.html` 的 `PERSONAS`，
/// 这里只取判定要用到的 `id → name`，不搬描述和图标。
enum RoutePersona {
    static let names: [String: String] = [
        "seagull": "实战全能",
        "jeli": "深度逆向",
        "sol": "极速直出",
        "omega": "CTF强攻",
        "codex": "轻量编码",
        "s": "规则路由",
        "sandbox": "沙箱执行",
        "omni": "全能执行",
        "auto": "自动",
    ]

    /// 判不出名字时回落 id 本身 —— 比显示空字符串强。
    static func name(_ id: String) -> String { names[id] ?? id }
}

/// 说话模式显示名。来源同上（`index.html` 的 `MODES`）。
enum RouteMode {
    static let names: [String: String] = [
        "auto": "自动模式",
        "plain": "简洁模式",
        "dev": "开发者模式",
        "rev": "逆向专家模式",
        "sec": "安全研究模式",
        "game": "游戏修改模式",
        "inject": "注入兼容模式",
    ]

    static func name(_ id: String) -> String { names[id] ?? id }

    /// 说话模式对**输出形状**的约束。
    ///
    /// 在此之前 `names` 是这张表里唯一的东西：判定出 `rev` 之后，注入块只多出
    /// 「说话模式 逆向专家模式」这七个字，模型没有任何依据知道该换个说法。
    /// 也就是说设置页那 7 个模式里，除「自动」，其余 6 个在行为上完全等价 ——
    /// 用户看着是选项，实际不起作用。
    ///
    /// 这里补的是**唯一的差异来源**。写法上刻意只约束形状，不写角色扮演：
    /// 「先给结论再给证据」是可执行的，「你是一位资深逆向专家」只会让模型
    /// 多写两段自我介绍。每条控制在一行内 —— 这段每轮都进上下文。
    ///
    /// `auto` 不在表里：自动模式的含义就是「不加额外约束」，
    /// 给它写一句反而会把「按需切换」锁死成一种固定口径。
    static let directives: [String: String] = [
        "plain": "只给结论和可直接执行的东西，不复述背景、不列备选方案、不解释你打算怎么做。",
        "dev": "给能直接跑的代码或命令，注明落盘路径和依赖；说明写进注释，不要单独铺一段散文。",
        "rev": "先给结论（关键函数 / 偏移 / 校验点 / 结构性判断），再给支撑它的证据链；不要从头通读再慢慢推。",
        "sec": "按攻击面组织：入口 → 可达路径 → 影响，每一步给可复现的验证命令，并标明该步的风险与副作用。",
        "game": "直接给内存结构：基址、偏移、指针链、字段类型。少谈原理，先让用户能定位到那个值。",
        "inject": "兼容优先：给出可直接塞进目标的最小实现，避开需要额外框架或运行时的写法，并说明注入点在哪。",
    ]

    /// 拿不到就没有额外约束 —— 调用点据此决定要不要出这一段。
    static func directive(_ id: String) -> String? {
        guard id != "auto" else { return nil }
        return directives[id]
    }
}

// MARK: - 设备档位（R31 §4）

/// 一个能力域的任务，目标机是哪一台。
///
/// 上一版是二分法：判到移动端/逆向/免杀/样本 → 报 iPhone；判到路由器/Web/云 → 报路由器；
/// **其余全部兜底报 iPhone**。实测下来写 pwn 脚本、域渗透、挖 CVE、看样本、内存取证、
/// 游戏外挂、口令破解、社工、靶场、方法论这 10 个域都在硬报「iPhone · arm64e · RootHide」。
///
/// 问题在于这些任务的目标机通常不是那台手机。写 pwn 脚本时给它一句「目标机是 arm64e/iOS」，
/// 它可能真按 arm64e 去算偏移、按 iOS 去挑 gadget。**错的前提比没前提更难发现**，
/// 所以三档制里 C 档明确说「不在这两台机器上」，而不是沉默地报一台。
///
/// 对应 `原型/lib/route-rules.js` 的 `DEV_SCOPE_IPHONE` / `DEV_SCOPE_ROUTER` /
/// `deviceScopeOf()`，两边必须一致（`实测/check-routes.py` 会比对）。
enum DeviceScope: String {
    /// A 档 · 任务就在这台 iPhone 上
    case iphone
    /// B 档 · 任务落在那台路由器 / 那台机器的网络侧
    case router
    /// C 档 · 本机只是操作端，目标在别处 —— 不给设备行
    case none
}

enum DeviceScopeRules {

    /// A 档只放两个域，比二分法那一版收紧了一档。
    ///
    /// 收紧的理由：「免杀与对抗」「样本分析」不算 iPhone 相关 —— 免杀的主战场是
    /// Windows 的 EDR/AV，样本可能是任意平台的 PE / ELF，都不落在这台手机上。
    /// 收紧不会漏掉 iOS 样本：样本若带 `ipa` / `dylib`，`移动端` 域的词长权重更高，
    /// 会把判定先抢走（实测「帮我破解这个 ipa」→ 移动端）。
    static let iphone: Set<String> = ["移动端", "逆向与二进制"]

    /// B 档 · 任务落在那台路由器 / 那台机器的网络侧
    static let router: Set<String> = [
        "路由器与中转站", "Web 与 API", "云与容器", "侦察与测绘",
        "协议分析", "数据渗出与 C2",
    ]

    /// C 档不单独存表 —— 没被上面两张表收进去的域，全部归 C。
    /// 这样新增能力域时默认落到「目标在别处」，是最安全的默认值：
    /// 漏报一台机器的规格，远好过给 AI 一个错的前提。
    static func scope(of domain: String) -> DeviceScope {
        if iphone.contains(domain) { return .iphone }
        if router.contains(domain) { return .router }
        return .none
    }
}

// MARK: - 设备上下文（R31 §3，零真值）

/// 判定结果该带哪些设备事实。
///
/// **v4.0 起任何档位都不给真值**：机型、系统版本、越狱形态、注入路径、插件清单、
/// 地址、账号全部不预置。理由两句话 ——
///   ① 会漂：装一个包、打一个补丁，上一轮的统计就全变；旧数字比没数字更坑。
///   ② 泄露面：这些值组合起来足以指纹化一台特定设备，源码外流时写了什么就露什么。
///
/// 用户 2026-11-09 18:51 的原话：
///   「完全没有必要，如果到时候有什么问题，我直接告诉他查我的手机所有的信息就完了呗，
///     这样只有我和ai知道这个事，外人无法获取」
///
/// 所以这里给的是「这类活该查什么、怎么查」，不是「这台机器是什么」。
/// 对应 `原型/lib/route-rules.js` 的 `deviceContextOf()`。
struct DeviceContext {
    /// 命中的档位（最多一个；C 档为空）
    let scopes: [DeviceScope]
    /// 一句话结论，直接进上下文
    let note: String
    /// 「该查什么、怎么查」的提示行
    let hints: [String]

    /// 拼成一段可注入 system prompt 的文本。
    ///
    /// 不拼成表格、不用 markdown 列表符号堆砌 —— 这段会被塞进每轮对话的上下文里，
    /// 每多一个字符都在挤真正干活的空间。用最短的句子说清三件事：
    /// 目标是什么机器、信息从哪来、别用旧值。
    var promptText: String {
        var lines: [String] = []
        lines.append(note)
        for h in hints { lines.append("- " + h) }
        return lines.joined(separator: "\n")
    }
}

enum DeviceContextBuilder {

    /// 按路由结果挑该带哪些设备事实。不是全量倒给 AI —— 全量会撑爆上下文，
    /// 也会让无关信息干扰判断。
    static func context(for decision: RouteDecision) -> DeviceContext {
        let scope = DeviceScopeRules.scope(of: decision.domain)
        var scopes: [DeviceScope] = []
        if scope != .none { scopes.append(scope) }

        var hints: [String] = []
        var note: String

        switch scope {
        case .iphone:
            note = "目标机是 iPhone。型号 / 系统 / 架构 / 越狱形态 / 注入链 / 已装插件 —— 全部现场查，不预置。"
            hints = [
                "查法：apple-device info 查机型/系统/内存，apple-device env 查越狱形态 —— 这两个跑在宿主 app 进程里，是真实 iOS 值",
                "越狱形态只认 env 的 jailbreak 字段：none / trollstore / rootless / rootful。trollstore 是「签名提权」不是越狱，没有注入钩子",
                "别用 shell 查越狱：shell 是 Alpine 假根，/var/jb、/var/mobile 在里面本来就不存在，uname / dpkg 查的也是容器不是 iOS",
                "没有 /var/jb 不等于没越狱",
                "数值会漂，别用上一轮的旧数字下判断",
            ]
        case .router:
            note = "目标机是路由器。型号 / 系统 / 内存 / 地址 —— 全部现场查，不预置。"
            hints = [
                "查法：SSH 进去读 /proc/meminfo、ip addr、df -h",
                "可用内存是那类机器的硬瓶颈，上新服务前先看实际值",
            ]
        case .none:
            // 空 scopes 时给一句说明，而不是硬塞一台机器的规格。
            // 让 AI 知道「手上这两台都不是这个活的目标」，比让它自己猜要好。
            note = "本机是操作端，不是这个任务的目标；不提供设备信息。"
        }

        return DeviceContext(scopes: scopes, note: note, hints: hints)
    }
}

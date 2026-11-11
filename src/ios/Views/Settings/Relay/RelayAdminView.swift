//
//  RelayAdminView.swift
//  Minis — 中转站后台（WebView）
//
//  直接把 relay.py 自带的后台页面装进 App，密码自动注入。
//
//  ============================================================
//  一、密码注入有**两处**，缺一个后台就出不来
//
//   ① localStorage['relayKey']
//      relay.py 的前端自己从 localStorage 取密钥，再拼到每个 fetch 的
//      X-Access-Key 头上。必须在 .atDocumentStart 注入 —— 等页面跑起来
//      再注就晚了（首屏那几个请求已经 401，页面渲染成「要输密码」）。
//
//   ② fetch / XMLHttpRequest 包一层
//      兜底：万一页面某处裸 fetch，请求头也带上。
//
//  ============================================================
//  二、左滑滑不动的真正原因（已修，别再改回去）
//
//  真正的病灶**不在网页**：relay.py 的表格和顶部菜单都写好了
//  overflow-x:auto。病灶在这里 ——
//     web.scrollView.delegate = coordinator      ← 为了支持双指缩放
//     web.scrollView.minimumZoomScale/maximumZoomScale = 1.0/5.0
//  一旦把 WKWebView 的内部 scrollView 接管过来，网页里那些
//  overflow-x:auto 的内联滚动区域（菜单、工具条、账户表格）的横向手势
//  就被父级 scrollView 抢走，手指横着拖，网页收不到事件。
//
//  所以这一版：
//     ✗ 不设 scrollView.delegate
//     ✗ 不设 minimumZoomScale / maximumZoomScale
//     ✗ 不补 viewport meta（页面自带，改了反而破坏适配）
//     ✓ allowsBackForwardNavigationGestures = false（别抢横向手势）
//  ============================================================
//  三、R43：表格被「按屏幕宽压扁」，不是不能滑（用户 2026-11-10 明确）
//
//  现象：账户表格右侧那几列（备注、余额、代理…）在手机上看不到，
//        而且怎么划都不动。用户原话「有的账号信息右侧很长」「不要固定死界面」。
//
//  根因在 relay.py 的表格自身，两处，都在它那边而不是在我们这边：
//    ① `table.acct{ table-layout:fixed; width:100% }`
//       fixed 布局 + 100% 宽 = 把总宽**锁死**成屏幕宽，列宽按 colgroup
//       的 px 值压缩分配。内容再长也只会在格子里省略号，永远不产生溢出，
//       于是「这表格不需要横滑」—— 浏览器就是这么理解的。
//    ② `html,body{ max-width:100vw; overflow-x:hidden }`（手机端媒体查询）
//       这道闸把整页的横向溢出裁掉。即使某个子元素真宽了，也滑不出去。
//
//  所以我们这边的任何「WKWebView 手势」都救不了它 —— 网页自己认定
//  没有横向可滚动内容，手势再灵敏也没东西可滚。这是**必须注入 CSS**
//  的那一类改动，注入的是样式，不是数据，不动功能逻辑。
//
//  注入的三条（见 horizontalScrollCSS）：
//    ① 表格切回 auto 布局并给 min-width，让它真的变宽、真的溢出
//    ② 直接父容器变成横向滚动容器
//    ③ 只放开**表格这一层**的横向裁剪，body 的 overflow 保持不动
//       —— 放宽 body 会让整页（含顶部栏）跟着左右晃，那是另一个毛病。
//
//  ⚠️ 这里的 CSS 只在 origin 匹配时注入（同 injectionScripts 的闸），
//     跨域子帧一律不动。
// ============================================================

import SwiftUI
import WebKit

struct RelayAdminView: View {

    @ObservedObject private var store = RelayStore.shared
    @State private var loading = false
    @State private var reloadToken = 0
    @State private var loadError = ""
    @State private var showSettings = false

    private var route: RelayRoute? { store.route }

    /// 显式读 vaultRevision 建立依赖。
    ///
    /// `RelayVault` 不是 ObservableObject，直接写 `RelayVault.shared.password()`
    /// 在 body 里是**读不出依赖**的：用户在设置页存了新密码，这个视图
    /// 不会重算，`updateUIView` 也不执行，注入脚本还是旧的（或者压根没装）。
    /// 结果就是「设置页说记住了，后台还是要求密钥」。
    /// 所以每个碰 Vault 的计算属性都先摸一下 vaultRevision。
    private var password: String {
        _ = store.vaultRevision
        return RelayVault.shared.password() ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // 密码失效时先给一条能看懂的话，再下面是网页本体。
            // 不把网页拦掉，避免把「后端临时 401」误判成「密码坏了」。
            if store.needsPassword {
                staleKeyBanner
            }

            ZStack {
                if let r = route, !password.isEmpty {
                    RelayWebContainer(
                        urlString: r.adminBase,
                        password: password,
                        reloadToken: reloadToken,
                        loading: $loading,
                        onLoadFailed: { msg in loadError = msg },
                        onLoadOK: { loadError = "" }
                    )
                    // 线路切换（在家↔在外）时整个容器换 key，
                    // 保证 WKWebView 重新按新地址建，而不是带着旧 cookie 复用
                    .id(r.adminBase)
                } else {
                    placeholder
                }

                // [R43-方案A] 首屏遮罩。网页加载期间盖一层，
                // 文案和底色都取模板 webmask（#f7f7f9 + 「正在连接中转站…」）。
                // 不加这层，慢线路时会先看到一片白，看不出是在连还是坏了。
                if loading && loadError.isEmpty {
                    loadingMask
                }

                if !loadError.isEmpty {
                    failCard
                }
            }

            // [R43-方案A] 底部地址栏，对齐模板 .webbar：
            // 左地址（11px 等宽、中间截断）+ 右连接状态，高 34。
            statusBar
        }
        .background(Color(.systemGroupedBackground))
        // [R43-方案A] 模板这张页的标题是「网页后台」，返回按钮上才是「中转站」。
        // 原生这里返回按钮的字由上一级页自动给，所以标题得对到「网页后台」。
        .navigationTitle("网页后台")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // [R43-方案A] 模板这张页的右上是**一个**刷新按钮（返回键在左）。
            // 原来这里还有一个加载转圈 —— 现在由 loadingMask 和底部状态栏
            // 两处表达加载中，转圈是第三个重复信号，去掉。
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        retry()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    // 齿轮是原生独有的入口（线路/密码设置），模板没有对应项，
                    // 但去掉会让「密码失效」时无处可改 —— 保留。
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                RelaySettingsView()
            }
        }
        .onAppear { store.refreshIfStale() }
        .onChange(of: store.route?.adminBase) { _ in
            // 线路变了 → 清掉上次的失败态，让新地址自己尝试
            loadError = ""
            reloadToken += 1
        }
        .onChange(of: store.vaultRevision) { _ in
            // 密码在别处被改了。必须强制建新容器：
            //   · 只改 updateUIView 里的注入脚本，已经在跑的那一页
            //     仍然用旧 key 渲染出来的（首屏 401 已经发完）。
            //   · 而 WKWebView 的 userContentController 是建时就绑定的，
            //     换脚本后不重载页面等于没换。
            // 直接 reloadToken += 1 走「重新 load」那条既有路径，
            // 同时把 loadError 清掉，别让上次的超时提示挡住新页面。
            loadError = ""
            reloadToken += 1
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            store.refreshIfStale()
        }
    }

    // MARK: - 模板对齐的两块壳（R43 · 方案 A）

    /// 首屏遮罩。取值照 `#pageMiniSys .webmask`：底色 `#F7F7F9`，
    /// 转圈 22 见方、灰色描边，文案 14pt 次级灰、距转圈 12。
    private var loadingMask: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.0)
            Text("正在连接中转站…")
                .font(.system(size: 14))
                .foregroundColor(Color(red: 0x8E/255, green: 0x8E/255, blue: 0x93/255))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0xF7/255, green: 0xF7/255, blue: 0xF9/255))
    }

    /// 底部地址栏。对齐 `#pageMiniSys .webbar`：
    /// 高 34、左右 16、上边 0.5 分隔线、底色 rgba(249,249,249,.94)、
    /// 地址 11pt 等宽中间截断、状态 11.5pt 绿色（失败转红）。
    ///
    /// 模板里这一条一直存在，是有用的：它把「现在连的是哪个地址」摆在明面上。
    /// 用户在外网进了内网地址时，一眼能看出连错了线，不用去设置页翻。
    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(route?.displayAddress ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(red: 0x8E/255, green: 0x8E/255, blue: 0x93/255))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(statusText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(statusOK
                                 ? Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255)
                                 : Color(red: 0xFF/255, green: 0x3B/255, blue: 0x30/255))
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0xF9/255, green: 0xF9/255, blue: 0xF9/255).opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
    }

    private var statusOK: Bool { loadError.isEmpty && !store.needsPassword }

    private var statusText: String {
        if !loadError.isEmpty { return "连不上" }
        if store.needsPassword { return "密码失效" }
        if loading { return "连接中" }
        return "已连接"
    }

    /// 没密码时的占位。
    ///
    /// [R33-直填] 原来这里是「还没有后台密码 + 去设置」两行字加一个跳转按钮。
    /// 用户要求取消这一步：进页面就能填地址和密码，填一次就记住。
    /// 现在直接嵌 `RelayQuickSetupForm`（与路由器页同一份，含外网地址）。
    ///
    /// [R44-补回] 这条功能在 R43 重排外壳时被我漏掉了，被退回到
    /// 「去设置」的老样子。用户当初明确要求的就是不要那一步，所以补回来。
    private var placeholder: some View {
        ScrollView {
            VStack(spacing: 14) {
                if route == nil {
                    ProgressView()
                        .padding(.top, 60)
                    Text("正在判定线路…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    RelayQuickSetupForm {
                        await store.refresh()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var failCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundColor(.orange)

            Text(loadError)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(route?.displayAddress ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 12) {
                Button("重试") { retry() }
                Button("线路设置") { showSettings = true }
            }
            .font(.footnote.weight(.medium))
        }
        .padding(22)
        .background(Color(.systemGroupedBackground))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func retry() {
        loadError = ""
        // 顺手重判一次线路（可能换了网络）
        store.refreshIfStale()
        reloadToken += 1
    }

    /// 密码失效（refresh 两条线路都 401）时的横幅。
    ///
    /// 不拦着网页不加载：万一只是后端瞬时抽风，用户还能看到页面。
    /// 但必须给一条「为什么进去是空的、去哪改」的话 ——
    /// relay.py 前端自己只会 toast 一句「需要访问密钥」，不告诉你怎么修。
    private var staleKeyBanner: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "key.slash.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("后台密码可能已经不对了")
                        .font(.footnote.weight(.medium))
                    Text(store.errorText.isEmpty
                         ? "重新填一次就会记住，之后不用再输。"
                         : store.errorText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重新填密码") { showSettings = true }
                        .font(.caption.weight(.medium))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.orange.opacity(0.10))
        }
    }
}

// MARK: - WKWebView 包装

/// 中转站后台专用的 WKWebView 子类，只做一件事：等 frame 铺满后再加载。
///
/// 背景见 RelayWebContainer.makeUIView 的 [R45-首屏半屏] 注释 —— 页面是
/// NavigationStack push 出来的，首屏 load 时 WKWebView 内部状态（frame /
/// safeAreaInsets）还没稳定，网页会按错误的 viewport 高度渲染，body 被固定
/// 成半屏，动画结束也不会长回去。
///
/// 这里重写 layoutSubviews，等到 frame 高度「连续两次相同且 > 1pt」（即稳定
/// 下来）才回调 onFirstLayout，由调用方在那一刻才发 load。
private final class RelayAdminWebView: WKWebView {

    /// 首次拿到稳定 frame 时回调（只触发一次）。
    var onFirstLayout: (() -> Void)?

    private var firedFirstLayout = false
    private var lastLayoutHeight: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !firedFirstLayout else { return }

        let h = bounds.height
        guard h > 1 else { return }
        // 高度连续两次一致，才认为布局稳定（push 动画 / safe area 调整结束）
        if abs(h - lastLayoutHeight) < 0.5 {
            firedFirstLayout = true
            onFirstLayout?()
        } else {
            lastLayoutHeight = h
        }
    }
}

private struct RelayWebContainer: UIViewRepresentable {

    let urlString: String
    let password: String
    let reloadToken: Int
    @Binding var loading: Bool
    var onLoadFailed: ((String) -> Void)?
    var onLoadOK: (() -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.websiteDataStore = .default()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false

        if !password.isEmpty {
            for script in Self.injectionScripts(password, origin: Self.origin(of: urlString)) {
                let s = WKUserScript(source: script,
                                     injectionTime: .atDocumentStart,
                                     forMainFrameOnly: false)
                cfg.userContentController.addUserScript(s)
                // 记下来，密码变更时要摘掉旧的
                context.coordinator.installedScripts.append(s)
            }
        }

        let web = RelayAdminWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator

        // ⚠️⚠️ 左滑的关键：**不要接管 scrollView**。
        //   不设 delegate、不设 zoomScale。
        //   设了就会抢走网页内 overflow-x:auto 容器的横向手势，
        //   表现就是「表格右半边怎么划都看不到」。
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.bounces = true
        web.scrollView.alwaysBounceVertical = true
        // 横向滚动显式打开：宽表右半边要能左右拖动。默认虽开，但被外层
        // 手势/样式压过之后容易失效，这里在原生侧再兜一次底。
        web.scrollView.isScrollEnabled = true
        web.scrollView.alwaysBounceHorizontal = true
        web.scrollView.showsHorizontalScrollIndicator = false

        web.isOpaque = false
        web.backgroundColor = .systemGroupedBackground
        web.scrollView.backgroundColor = .systemGroupedBackground
        // .never：让网页自己管 inset，避免系统反复插入导致上下跳动
        web.scrollView.contentInsetAdjustmentBehavior = .never

        context.coordinator.webView = web
        context.coordinator.lastLoaded = urlString
        context.coordinator.lastPassword = password
        context.coordinator.lastToken = reloadToken

        // [R45-首屏半屏] 不要在 makeUIView 里立刻 load。
        //
        // 这个页面是 NavigationStack push 出来的：push 动画期间 WKWebView 的
        // frame 还处于中间态（比最终高度矮一截）。此时就 load，网页会按这个
        // 半屏高度算 viewport、把 body 高度固定住；动画结束 frame 恢复全屏，
        // 网页却不会跟着长回去 —— 表现就是「第一次进去半屏、退出重进才好」。
        //
        // 修法：把首次 load 延迟到 frame 真正铺满之后再发（见
        // RelayAdminWebView.layoutSubviews 的 onFirstLayout 回调）。第二次进
        // 因为 frame 一开始就对了，不受影响。
        let initialURL = urlString
        web.onFirstLayout = { [weak web] in
            guard let web = web, let url = URL(string: initialURL) else { return }
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            web.load(req)
        }
        // 兜底：万一 layoutSubviews 没有触发第二次（极端情况下 frame 一次
        // 到位），0.8s 后强制 load，保证页面一定能出来。onFirstLayout 已触发
        // 的话这里会因 web.url != nil 而跳过，不会重复加载。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak web] in
            guard let web = web else { return }
            guard web.url == nil, !web.isLoading else { return }
            if let url = URL(string: initialURL) {
                var req = URLRequest(url: url)
                req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                web.load(req)
            }
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Coordinator 存的是创建那一刻的结构体副本，回调会变旧，每次更新刷新它
        context.coordinator.parent = self

        // ① 用户点了刷新 / 线路变了
        if reloadToken != context.coordinator.lastToken {
            context.coordinator.lastToken = reloadToken
            context.coordinator.lastLoaded = urlString
            if let url = URL(string: urlString) {
                var req = URLRequest(url: url)
                req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                uiView.load(req)
            } else {
                uiView.reload()
            }
            return
        }

        // ② 密码改了 → 补注入脚本再重载。
        //
        // 不能只 evaluateJavaScript 补 localStorage：
        //   · makeUIView 时如果还没密码，userContentController 里根本
        //     没装注入脚本 —— 之后用户去设置页填了密码回来，
        //     atDocumentStart 那两段永远不会执行，页面一刷新又是空 key。
        //   · 表现就是「明明填过密码，进后台还要再输一遍」。
        // 所以密码变化时要把脚本**补进控制器**，再重载。
        if password != context.coordinator.lastPassword {
            context.coordinator.lastPassword = password
            if password.isEmpty {
                return
            }

            // 先摘掉旧的（可能换了密码），再装新的，避免叠多份。
            //
            // ⚠️ WKUserContentController **没有** removeUserScript(_:)。
            //   公开 API 只有两个：addUserScript(_:) 和 removeAllUserScripts()。
            //   之前那句 `installedScripts.forEach { ucc.removeUserScript($0) }`
            //   是凭印象写的，报 "value of type 'WKUserContentController'
            //   has no member 'removeUserScript'" —— 一直被 WMO 的 OOM 掩盖着。
            //
            // 整批摘是有副作用的：removeAllUserScripts() 会连系统注入
            // （比如某些内建 handler）一起清掉，所以摘完必须**紧接着**
            // 把我方脚本全部重装 —— 下面的 for 循环正好干这件事，中间不能
            // 插早退。Coordinator 里的 installedScripts 仍然要维护：它不是
            // 用来摘除的，而是给 makeUIView 判重、给后续逻辑记录「装了什么」。
            let ucc = uiView.configuration.userContentController
            ucc.removeAllUserScripts()
            context.coordinator.installedScripts = []
            for src in Self.injectionScripts(password, origin: Self.origin(of: urlString)) {
                let s = WKUserScript(source: src,
                                     injectionTime: .atDocumentStart,
                                     forMainFrameOnly: false)
                ucc.addUserScript(s)
                context.coordinator.installedScripts.append(s)
            }

            // 当前这一页已经用空 key 载入过了，补一次并重载让注入生效
            uiView.evaluateJavaScript(
                "try{localStorage.setItem('relayKey',\(jsStringLiteral(password)))}catch(e){}",
                completionHandler: nil)
            uiView.reload()
            return
        }

        // ③ 地址变了 → 重新加载到新地址。
        //
        // 判据必须用 lastLoaded（上次真正加载的地址），不能用 uiView.url：
        // 首次渲染时 uiView.url 还是 nil，拿它比永远不等，会把刚发出的
        // 那次 load 再发一遍 —— 网页被加载两次。
        guard urlString != context.coordinator.lastLoaded else { return }
        guard let url = URL(string: urlString) else { return }
        context.coordinator.lastLoaded = urlString
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        uiView.load(req)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// 从 base URL 取 origin（`scheme://host[:port]`），给注入脚本做同源闸。
    ///
    /// 不能用 `URL(string:).absoluteString` 或 host 简单拼：`URL.port` 与
    /// `URL.scheme` 都要参与，否则 `http://h:8080` 和 `https://h` 会被算成
    /// 同一个 origin，而浏览器的 `location.origin` 是带端口的 —— 判等永远不成立，
    /// 脚本就成了死代码，密钥又注入到所有帧。
    static func origin(of urlString: String) -> String {
        guard let u = URL(string: urlString),
              let scheme = u.scheme?.lowercased(),
              let host = u.host, !host.isEmpty else { return "" }
        let defaultPort = scheme == "https" ? 443 : 80
        if let p = u.port, p != defaultPort {
            return "\(scheme)://\(host):\(p)"
        }
        return "\(scheme)://\(host)"
    }

    /// 只做横向滚动的那段 CSS（R43）。
    ///
    /// 网页自己的 `table.acct{table-layout:fixed;width:100%}` 把总宽锁成屏幕宽，
    /// 所以「表格里没有可滚内容」—— 手势再灵敏也没东西可滑。
    /// 这里把宽度还给内容，并让它自己成为一个横向滚动容器。
    ///
    /// 三条改动，逐条对应一个问题：
    ///   ① `table-layout:auto` + `width:max-content`
    ///      让表格按内容真实宽度排开，而不是被压成屏幕宽。
    ///   ② 另外三张会在手机上挤扁的表（rltab / models-table / doc-tbl）同理。
    ///   ③ 把表格的**直接父容器**变成 `overflow-x:auto`。
    ///      不改 body —— body 一放开，整页（含顶部导航）都会跟着左右晃。
    ///
    /// `-webkit-overflow-scrolling:touch` 是必须的：不加的话 iOS 上
    /// 滚动是逐帧同步的，手指一停就戛然而止，手感很硬。
    ///
    /// - Parameter origin: 本页 origin，用于同源闸（与密钥注入同一套判据）。
    static func horizontalScrollScript(origin: String) -> String {
        """
        (function(){
          if (location.origin !== \(jsStringLiteral(origin))) return;
          if (window.__minisRelayHScroll) return;
          window.__minisRelayHScroll = true;

          var css = [
            /* ⓪ 根节点放开横向：后台响应式样式常把 html/body 或外层包成
               overflow-x:hidden/clip，内层就算开了 auto 也被裁住，横滑像锁死。 */
            'html,body{overflow-x:visible !important;max-width:none !important;}',

            /* ① 账户表格：从「按屏宽压缩」改成「按内容展开」 */
            'table.acct{table-layout:auto !important;width:max-content !important;min-width:100% !important}',
            'table.acct td,table.acct th{white-space:nowrap !important}',
            'table.acct td{overflow:visible !important;text-overflow:clip !important}',

            /* ② 另外三张在手机上会被挤扁的表 */
            'table.rltab,table.models-table,.doc-tbl{table-layout:auto !important;width:max-content !important;min-width:100% !important}',
            'table.models-table td,table.models-table th,table.rltab td,table.rltab th{white-space:nowrap !important}',

            /* [R56-全表放开] 其余所有数据表通杀：模型管理/概览/报表/签到/路由
               等页面还有一堆别的 class 的表（或没 class 的表），逐个枚举
               永远漏。凡是「列数 > 3 的表」都按内容展开 —— 手机上列多的
               表只有横滑一条路，没有例外。列少的布局表不受影响
               （max-content 不会超过本来就该有的宽度）。 */
            'table{table-layout:auto !important;width:max-content !important;min-width:100% !important}',
            'table td,table th{white-space:nowrap !important}',

            /* ③ 装表格的容器成为横向滚动条：
               已知容器 + 通杀「含有宽表的直接父级」。
               通杀规则：body 下任何 div，只要它的直接子元素里有变宽的
               table，就给它开横向滚动。用 JS 找比纯 CSS 通配安全 ——
               给所有 div 加 overflow-x 会把页面布局打成碎片。 */
            '.card-b{overflow-x:auto !important;-webkit-overflow-scrolling:touch !important}',
            '.doc-tbl{display:block !important;overflow-x:auto !important;-webkit-overflow-scrolling:touch !important}',

            /* 本来就有 overflow-x:auto 的那几块，补上手感 */
            '.heat,.rl-list,.rp-heatwrap,#nav,.tools,.dw-tabs{-webkit-overflow-scrolling:touch !important}',

            /* 隐藏横向滚动条，滑动仍然可用 */
            '.card-b::-webkit-scrollbar,.doc-tbl::-webkit-scrollbar{height:0 !important}'
          ].join('\\n');

          function inject(){
            if (document.getElementById('__minis_hscroll')) return;
            var s = document.createElement('style');
            s.id = '__minis_hscroll';
            s.textContent = css;
            (document.head || document.documentElement).appendChild(s);

            /* [R56] 通杀容器：找出所有装宽表的直接父级，开横向滚动。
               DOM 动态渲染（签到中心/模型管理是 JS 刷出来的）也能被
               MutationObserver 接住。 */
            /* 把宽表祖先链上被裁成 hidden/clip 的容器逐个放开横向滚动；
               只开直接父级不够，中间夹一层 overflow-x:hidden 的外包 div，
               里面照样拖不动。 */
            function openAncestorClip(el){
              var p = el.parentElement;
              while (p && p !== document.documentElement) {
                var cs = getComputedStyle(p);
                if (cs.overflowX === 'hidden' || cs.overflowX === 'clip') {
                  p.style.overflowX = 'auto';
                  p.style.webkitOverflowScrolling = 'touch';
                }
                p = p.parentElement;
              }
            }
            function widenParents(){
              document.querySelectorAll('table').forEach(function(t){
                if (t.scrollWidth <= t.clientWidth + 2) return;  // 没溢出，不用管
                var p = t.parentElement;
                if (p) {
                  if (getComputedStyle(p).overflowX !== 'auto') {
                    p.style.overflowX = 'auto';
                    p.style.webkitOverflowScrolling = 'touch';
                  }
                  openAncestorClip(t);
                }
              });
            }
            widenParents();
            /* atDocumentStart 注入时 document.body 可能还是 null，
               等 DOMContentLoaded 再挂 observer（inject 本身也会在那时重跑）。 */
            if (document.body) {
              new MutationObserver(widenParents).observe(document.body, {childList:true, subtree:true});
            } else {
              document.addEventListener('DOMContentLoaded', function(){
                new MutationObserver(widenParents).observe(document.body, {childList:true, subtree:true});
              });
            }
          }

          inject();
          document.addEventListener('DOMContentLoaded', inject);
        })();
        """
    }

    /// 两段注入脚本：localStorage 优先，请求头兜底。
    /// 顺序不能反 —— localStorage 必须第一条，页面首屏请求就靠它。
    ///
    /// ⚠️ 两段都先判 `location.origin`：
    ///   `forMainFrameOnly: false` 是必须的（后台可能用同源 iframe 装内容），
    ///   但它同时会把脚本注入**所有**子帧 —— 包括第三方 iframe。
    ///   不判来源的话，任何嵌进来的外部页面都会被我们改写 `fetch`，
    ///   于是 `X-Access-Key` 就跟着它的请求发出去了 —— 后台密码直接泄给第三方。
    ///   所以脚本第一句就是 `if (location.origin !== <本页 origin>) return;`。
    static func injectionScripts(_ password: String, origin: String) -> [String] {
        let guardJS = """
          // 只在本站帧里生效；跨域子帧原样跳过，绝不把密钥带出去
          if (location.origin !== \(jsStringLiteral(origin))) return;
        """

        let keyJS = """
        (function(){
        \(guardJS)
          try {
            var K = \(jsStringLiteral(password));
            if (localStorage.getItem('relayKey') !== K) {
              localStorage.setItem('relayKey', K);
            }
          } catch(e) {}
        })();
        """

        let headerJS = """
        (function(){
        \(guardJS)
          var K = \(jsStringLiteral(password));
          if (window.__minisRelayKeyInstalled) return;
          window.__minisRelayKeyInstalled = true;

          var origFetch = window.fetch;
          if (origFetch) {
            window.fetch = function(input, init) {
              init = init || {};
              try {
                var h = new Headers(init.headers || {});
                if (!h.has('X-Access-Key')) h.set('X-Access-Key', K);
                init.headers = h;
              } catch(e) {}
              return origFetch(input, init);
            };
          }

          var origOpen = XMLHttpRequest.prototype.open;
          var origSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(m, u) {
            this.__minisUrl = u;
            return origOpen.apply(this, arguments);
          };
          XMLHttpRequest.prototype.send = function(body) {
            try {
              if (!this.__minisKey) {
                this.setRequestHeader('X-Access-Key', K);
                this.__minisKey = 1;
              }
            } catch(e) {}
            return origSend.apply(this, arguments);
          };
        })();
        """

        return [keyJS, headerJS, horizontalScrollScript(origin: origin)]
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: RelayWebContainer
        weak var webView: WKWebView?
        var lastToken: Int = 0
        var lastLoaded = ""
        var lastPassword = ""
        /// 当前已装进 userContentController 的注入脚本。
        /// 密码变更时要先摘掉这些，否则会叠成两份。
        var installedScripts: [WKUserScript] = []

        /// 慢加载兜底：连接被黑洞掉时 WKWebView 可能几十秒都不回调 didFail，
        /// 用户看到的就是「白屏一直转圈」。超时没起来就主动报错。
        ///
        /// 定 30 秒而不是 20 秒：路由器刚重启完那 1 分钟，Cloudflare 隧道
        /// 在重连（实测冷启动 3.38s，重连期更久）。20 秒刚好卡在边界上，
        /// 用户会看到「地址不通」以为坏了。30 秒更稳，正常加载根本用不到。
        private static let slowHintSeconds: TimeInterval = 30

        private var slowItem: DispatchWorkItem?

        init(parent: RelayWebContainer) {
            self.parent = parent
            self.lastToken = parent.reloadToken
        }

        private func armSlowHint() {
            slowItem?.cancel()
            let limit = Int(Self.slowHintSeconds)
            let item = DispatchWorkItem { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                guard wv.isLoading else { return }
                wv.stopLoading()
                self.parent.loading = false
                self.parent.onLoadFailed?("\(limit) 秒没加载出来\n地址不通，或当前网络访问不了它")
            }
            slowItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.slowHintSeconds, execute: item)
        }

        func webView(_ webView: WKWebView,
                     didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
            armSlowHint()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            slowItem?.cancel()
            parent.loading = false
            parent.onLoadOK?()

            // 有些页面会自己清 key，或二次进入时内存里的丢了，这里补一次
            let p = parent.password
            if !p.isEmpty {
                webView.evaluateJavaScript(
                    "try{localStorage.setItem('relayKey',\(jsStringLiteral(p)))}catch(e){}",
                    completionHandler: nil)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            slowItem?.cancel()
            parent.loading = false
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled { return }
            parent.onLoadFailed?(RelayWebError.explain(error, addr: parent.urlString))
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            slowItem?.cancel()
            parent.loading = false
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled { return }
            parent.onLoadFailed?(RelayWebError.explain(error, addr: parent.urlString))
        }

        /// 网页内容进程被系统干掉（内存不足等）
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            slowItem?.cancel()
            parent.loading = false
            parent.onLoadFailed?("网页进程被系统结束了。点重试即可恢复。")
        }
    }
}

// MARK: - 错误翻译

/// 把 NSURLError 翻译成「用户照着能动手」的一句话，
/// 而不是系统的 "A server with the specified hostname could not be found."
private enum RelayWebError {
    static func explain(_ error: Error, addr: String) -> String {
        let ns = error as NSError
        let host = URL(string: addr)?.host ?? addr
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "域名解析不到：\(host)\n可能域名当前解析不了，或网络被拦"
            case NSURLErrorCannotConnectToHost:
                return "能解析但连不上：\(host)\n后台可能没启动，或端口不对"
            case NSURLErrorTimedOut:
                return "连接超时：\(host)\n地址不通，或当前网络访问不了它"
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateNotYetValid:
                return "证书有问题：\(host)\n地址对但 HTTPS 证书不受信任"
            case NSURLErrorNotConnectedToInternet:
                return "当前没有网络连接"
            case NSURLErrorNetworkConnectionLost:
                return "连接被中断，请重试"
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return "系统拦截了这次明文 HTTP 请求（ATS）"
            default:
                break
            }
        }
        let msg = ns.localizedDescription
        return msg.isEmpty ? "打不开 \(host)" : "打不开 \(host)\n\(msg)"
    }
}

/// 把 Swift 字符串安全地写成 JS 字面量。
/// 密码里出现引号/反斜杠是常事，直接拼进源码会把脚本写坏。
private func jsStringLiteral(_ s: String) -> String {
    var out = "\""
    for c in s {
        switch c {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if let ascii = c.asciiValue, ascii < 0x20 {
                out += String(format: "\\u%04x", Int(ascii))
            } else {
                out.append(c)
            }
        }
    }
    return out + "\""
}

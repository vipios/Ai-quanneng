//
//  GitHubAccountView.swift
//  Minis — 设置页「GitHub 账号」
//
//  ============================================================
//  这个页面回答三个问题，顺序也按这个来：
//    1. 登录了吗？          → 第一段
//    2. 云端编译能用了吗？  → 第二段（仓库配置 + 权限检查）
//    3. 什么时候会用它？    → 第三段（本机 / 云端的分工说明）
//
//  为什么单独讲第 3 点：用户要的是「GitHub 作为兜底」，
//  不是「什么都往云端推」。界面上必须把这条规则写死在那儿，
//  否则用起来会怀疑它是不是偷偷把什么都传上去了。
//  ============================================================
//
//  ⚠️ 登录用 Device Flow，所以界面要有「8 位码」这一步。
//     这个码是**给用户看的**，不是内部状态 —— 要能长按复制，
//     要能直接点开 GitHub 的输码页面。
//  ============================================================

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct GitHubAccountView: View {

    @ObservedObject private var store = GitHubStore.shared
    @State private var verifying = false
    @State private var verifyMessage = ""
    @State private var verifyOK: Bool?
    @State private var showSignOutConfirm = false
    @Environment(\.openURL) private var openURL

    // [R40-密令登录] 密令输入面板
    @State private var showSecretSheet = false
    @State private var secretDraft = ""
    @State private var secretError = ""

    var body: some View {
        Form {
            masterSwitchSection
            accountSection
            if store.signedIn {
                scopeSection
                repoSection
                routeSection
            }
            aboutSection
        }
        .navigationTitle("GitHub 账号")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.reloadFromDisk() }
        .sheet(isPresented: $showSecretSheet) {
            secretSheet
        }
        .alert("退出 GitHub 账号？", isPresented: $showSignOutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { store.signOut() }
        } message: {
            Text("只会清掉这台手机上保存的令牌。GitHub 那边的授权还在，要在网页上撤销请去「设置 → 应用授权」。")
        }
    }

    // MARK: - [R40-密令登录] 输入面板
    //
    // 三步说清用户要做什么：去哪建、建哪个、粘哪儿。
    // 不写「请粘贴您的 Personal Access Token」这种话 —— 用户不知道
    // 那是什么。直接给「密令」+ 一个能点的入口。

    private var secretSheet: some View {
        NavigationStack {
            Form {
                Section {
                    // 不设 secure 输入：令牌需要能看见才能核对有没有粘全，
                    // 而且它马上就会变成「••••」的已登录状态。
                    TextField("ghp_… 或 github_pat_…", text: $secretDraft, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(2...4)
                        .onChange(of: secretDraft) { _ in secretError = "" }
                } header: {
                    Text("密令")
                } footer: {
                    if secretError.isEmpty {
                        Text("粘进来就行。首尾的空格、换行、`Bearer ` 前缀都会自动去掉。")
                    } else {
                        Text(secretError)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button {
                        if let u = URL(string: buildTokenURL) { openURL(u) }
                    } label: {
                        Label("去 GitHub 建一个", systemImage: "safari")
                    }
                } footer: {
                    // 权限勾选是最容易出错的一步，单独讲。
                    // 经典令牌要 repo + workflow；少了 workflow 会 403。
                    Text("建的时候勾上 **repo** 和 **workflow** 两项。少了 workflow，推送能成功但编译触发不了。有效期限随便选，过期了回来重新登一次。")
                }
            }
            .navigationTitle("用密令登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showSecretSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.secretSigningIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("登录") { submitSecret() }
                            .disabled(secretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    /// 建令牌的深链。
    ///
    /// 带上 scopes 参数，GitHub 会把对应权限预先勾好 ——
    /// 用户少一次「该勾哪几个」的判断，也就少一次因为漏勾而 403。
    private var buildTokenURL: String {
        "https://github.com/settings/tokens/new?scopes=repo,workflow&description=全能AI"
    }

    private func submitSecret() {
        let s = secretDraft
        Task {
            let err = await store.signIn(withSecret: s)
            if let err {
                secretError = err
            } else {
                // 成功：清掉明文，关面板
                secretDraft = ""
                secretError = ""
                showSecretSheet = false
            }
        }
    }

    // MARK: - 零、总开关
    //
    // [T-minis-gh-fallback-switch] 用户要求：「我打开了才有兜底方案，
    // 我不开他就没有这个选择项，AI 就不知道有这个功能了。」
    //
    // 所以这个 Toggle 不是「隐藏一个按钮」，它接的是 AgentToolSwitch，
    // 关掉时：工具不在 schema 里、提示词不提、派发器拒绝残留调用。
    // 三处同时生效，AI 侧确实不存在这个能力。
    //
    // 放在最上面，因为它决定下面几段有没有意义 —— 关着的时候填仓库、看
    // 权限都只是准备工作，不会真的发生任何事。footer 把这点说清楚。

    @ViewBuilder
    private var masterSwitchSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { store.fallbackEnabled },
                set: { store.setFallbackEnabled($0) }
            )) {
                // 一行标题，不带副标题、不带 footer。
                // 开关的语义在「智能体工具」页已经写清；这个页面是配置面，
                // 用户要的是拨一下就走，不是再读一遍解释。
                Text("云端编译兜底")
            }
            // 条件不齐时不许打开：打开了也只会让 AI 反复调一个必然失败的工具，
            // 白烧一轮对话。置灰比事后报错诚实 —— 这也是唯一的状态提示，
            // 不需要额外一行小字去解释「为什么拨不动」。
            .disabled(!store.fallbackEnabled && !store.canToggleFallback)
        }
    }

    // MARK: - 一、账号
    //
    // [R40-密令登录] 这里原来是「只有设备码登录一条路」。
    //
    // 那条路要求 App 里有 OAuth App 的 Client ID，而 `GitHubAuth.clientID`
    // 一直是空串 —— 于是这个页面永远停在「还没有配置 Client ID」，
    // 一个能用的入口都没有。用户要的是「能登进去」，
    // 所以主路改成密令（粘令牌），设备码那条件保留但如实标明不可用。
    //
    // 两条路的差别必须写清楚，否则用户会以为密令是自己多此一举：
    //   密令   —— 现在就能用，要在 GitHub 网页上建一个令牌；
    //   设备码 —— 体验更好（浏览器点一下），但需要 Client ID。

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let dc = store.deviceCode {
                // 设备码流程已经在跑，优先把它显示完 ——
                // 这时再显示密令输入框会把用户正在做的事打断。
                deviceCodeBlock(dc)
            } else if store.signedIn, let acct = store.account {
                signedInRow(acct)
            } else {
                secretSignInRow
                if store.polling {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.8)
                        Text("正在向 GitHub 请求验证码…").foregroundColor(.secondary)
                    }
                } else {
                    deviceFlowRow
                }
            }

            if !store.loginError.isEmpty {
                Text(store.loginError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("账号")
        } footer: {
            if !store.signedIn && store.deviceCode == nil {
                Text("密令就是 GitHub 的 Personal Access Token，只在登录那一次经过网络，之后以加密形式存在这台手机上。")
            }
        }
    }

    /// 主路：粘贴密令登录。
    ///
    /// 为什么用 sheet 而不是在这一行里放个 TextField：
    /// 令牌是一长串字符，行内输入框在 Form 里只有一行的宽度，
    /// 粘完看不见全貌、也没法核对；而且粘贴动作本身需要一个
    /// 「粘贴并登录」的确认步骤，行内输入框没有这个边界。
    private var secretSignInRow: some View {
        Button {
            secretDraft = ""
            secretError = ""
            showSecretSheet = true
        } label: {
            HStack {
                Image(systemName: "key.horizontal.fill")
                    .foregroundColor(.orange)
                Text("用密令登录")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// 备路：设备码登录。Client ID 没配时如实置灰。
    private var deviceFlowRow: some View {
        Group {
            if store.configured {
                Button {
                    store.startSignIn()
                } label: {
                    HStack {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("用设备码登录")
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                // 不隐藏，而是显示成不可用 + 一句原因。
                // 藏起来的话，用户从别处听说「这 App 能用设备码登录」时
                // 会找不到入口、以为坏了。
                HStack {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundColor(.secondary)
                    Text("用设备码登录")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("需要客户端标识")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // [R40-密令登录] 原来这里有 `configMissingRow`（「还没有配置 Client ID」
    // 那一整块警告）和 `signInButton`（唯一的登录按钮）。
    // 改成密令为主路后，两者都没有引用点了：
    //   · Client ID 缺失不再是「整页报错」，而是设备码那一行的一枚灰字；
    //   · 登录按钮被 `secretSignInRow` 取代。
    // 按「不留死代码」的规矩一起删掉，别给下一个人留两个没人调用的属性。

    /// 显示 8 位码。这是整个登录流程里唯一需要用户动手的一步。
    private func deviceCodeBlock(_ dc: GitHubDeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在 GitHub 上输入这串码")
                .font(.subheadline.weight(.medium))

            // 码本身做大、做等宽、可长按复制
            Text(dc.userCode)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .tracking(3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = dc.userCode
                } label: {
                    Label("复制码", systemImage: "doc.on.doc")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)

                Button {
                    if let u = URL(string: dc.verificationURI) { openURL(u) }
                } label: {
                    Label("打开 GitHub", systemImage: "safari")
                        .font(.footnote)
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                if store.polling {
                    ProgressView().scaleEffect(0.7)
                    Text("等你授权…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if store.secondsLeft > 0 {
                    Text("\(store.secondsLeft / 60):\(String(format: "%02d", store.secondsLeft % 60)) 后失效")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundColor(store.secondsLeft < 60 ? .red : .secondary)
                }
            }

            Button("取消", role: .cancel) {
                store.cancelSignIn()
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }

    private func signedInRow(_ acct: GitHubAccount) -> some View {
        HStack(spacing: 12) {
            // 头像。加载失败就退回一个占位图标 —— 不能因为拉不到图就不显示这一行
            AsyncImage(url: URL(string: acct.avatarURL ?? "")) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(acct.displayName)
                    .font(.subheadline.weight(.semibold))
                Text("@\(acct.login)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - 二、权限

    /// 云端编译必须的两项，固定排在前面；其余按令牌实际授予的 scope 全量列出。
    private let requiredScopes = ["repo", "workflow"]

    /// 要展示的 scope 顺序：必需项在前（缺了也列出来标未授权），其余按字母序。
    private var orderedScopes: [String] {
        let owned = Set(store.account?.scopes ?? [])
        let head = requiredScopes
        let rest = owned.subtracting(requiredScopes).sorted()
        return head + rest
    }

    /// GitHub scope → 中文释义；没有收录的直接显示原始 scope 名。
    private func scopeLabel(_ scope: String) -> String {
        let map: [String: String] = [
            "repo": "推代码到仓库",
            "workflow": "触发 Actions 编译",
            "read:user": "读取用户资料",
            "user": "读取并写入用户资料",
            "read:org": "读取组织信息",
            "write:org": "写入组织信息",
            "admin:org": "管理组织",
            "gist": "读写 Gist 片段",
            "notifications": "读取通知",
            "read:repo_hook": "读取仓库钩子",
            "write:repo_hook": "写入仓库钩子",
            "admin:repo_hook": "管理仓库钩子",
            "admin:org_hook": "管理组织钩子",
            "delete_repo": "删除仓库",
            "public_repo": "访问公开仓库",
            "repo:status": "读取提交状态",
            "repo_deployment": "读取部署信息",
            "read:packages": "读取软件包",
            "write:packages": "写入软件包",
            "delete:packages": "删除软件包",
            "read:project": "读取项目看板",
            "write:project": "写入项目看板",
            "admin:project": "管理项目看板",
            "project": "访问项目看板",
            "enterprise": "访问企业账户",
            "follow": "关注用户",
            "read:email": "读取邮箱地址",
            "email": "读取邮箱地址",
            "profile": "读取个人资料"
        ]
        return map[scope] ?? scope
    }

    private var scopeSection: some View {
        Section {
            if store.account?.scopeUnknown == true {
                // 细粒度令牌读不到响应头 scope：画成问号，不是未授权。
                scopeRow(scope: "repo", granted: nil)
                scopeRow(scope: "workflow", granted: nil)
            } else if orderedScopes.isEmpty {
                Text("未读取到权限范围")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(orderedScopes, id: \.self) { s in
                    let owned = store.account?.scopes.contains(s) ?? false
                    scopeRow(scope: s, granted: owned)
                }
            }

            Button {
                Task {
                    verifying = true
                    let r = await store.verifyToken()
                    verifyOK = r.ok
                    verifyMessage = r.message
                    verifying = false
                }
            } label: {
                HStack {
                    Text("测一下这个令牌")
                    Spacer()
                    if verifying { ProgressView().scaleEffect(0.7) }
                }
            }
            .disabled(verifying)

            if let ok = verifyOK, !verifyMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(ok ? .green : .red)
                    Text(verifyMessage)
                        .font(.caption)
                        .foregroundColor(ok ? .secondary : .red)
                }
            }
        } header: {
            Text("权限")
        } footer: {
            // [R40-密令登录] 权限读不到时不能显示成「缺 repo、workflow」。
            // 细粒度令牌本来就不在响应头里回 scopes，照旧文案会让人
            // 以为自己建错了令牌、跑去重建一个 —— 那是最浪费时间的误导。
            if store.account?.scopeUnknown == true {
                Text("这枚密令读不到权限范围（细粒度令牌就是这样）。能推不能推，等第一次推送时 GitHub 的回答为准 —— 被拒的话它会明确说缺哪一项。")
            } else if let missing = store.account?.missingScopes, !missing.isEmpty {
                Text("缺 \(missing.joined(separator: "、"))。少了这两项，推代码或触发编译会被 GitHub 拒绝。")
                    .foregroundColor(.orange)
            } else {
                Text("云端编译必须 `repo`、`workflow` 两项；其余权限按这枚令牌实际授予的范围全部列出。权限的增减需要前往 GitHub 后台修改令牌。")
            }
        }
    }

    /// granted: true 已授权 / false 未授权 / nil 未知（问号）。
    private func scopeRow(scope: String, granted: Bool?) -> some View {
        HStack {
            Image(systemName: granted == nil ? "questionmark.circle.fill"
                                      : (granted == true ? "checkmark.circle.fill" : "circle.dashed"))
                .foregroundColor(granted == nil ? .secondary : (granted == true ? .green : .orange))
            Text(scopeLabel(scope))
            Spacer()
            Text(scope)
                .font(.caption)
                .monospaced()
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 三、仓库配置

    private var repoSection: some View {
        Section {
            HStack {
                Text("仓库")
                    .frame(width: 76, alignment: .leading)
                TextField("用户名/仓库名", text: $store.repoDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .monospaced()
                    .font(.callout)
            }
            HStack {
                Text("分支")
                    .frame(width: 76, alignment: .leading)
                TextField("main", text: $store.branchDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .monospaced()
                    .font(.callout)
            }
            HStack {
                Text("工作流")
                    .frame(width: 76, alignment: .leading)
                TextField("build.yml", text: $store.workflowDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .monospaced()
                    .font(.callout)
            }

            // 显式保存，不做「输入即保存」。
            //
            // 为什么不用 onChange 自动存：`saveRepoConfig()` 会把归一化后的值
            // 回写到 draft（把 `https://github.com/a/b` 截成 `a/b`），
            // 而回写又会触发 onChange —— 形成「改 → 存 → 回写 → 再存」的循环。
            // 加标志位去挡能修，但会让「用户在输入的中间态被悄悄改写」
            // 这件事更难理解。一个按钮，行为最直白。
            Button {
                store.saveRepoConfig()
            } label: {
                HStack {
                    Text("保存推送目标")
                    Spacer()
                    if store.repoDraft != store.persistedRepo
                        || store.branchDraft != store.persistedBranch
                        || store.workflowDraft != store.persistedWorkflow {
                        Text("未保存")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
        } header: {
            Text("推送目标")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                // [R53-自动推送目标] 不填也能推：没配置时推送会自动建仓。
                Text("这里可以不填 —— 没配置时，推送会自动用项目名创建新仓库并装好编译工作流；配置过就一直沿用同一个仓库升级（老项目不再重复建）。要指定仓库才填 `用户名/仓库名`。")
                Text("当前状态：\(store.cloudReadiness)")
                    .foregroundColor(store.canUseCloudBuild ? .green : .secondary)
            }
        }
    }

    // MARK: - 四、编译路由

    private var routeSection: some View {
        Section {
            HStack {
                Label("本机工具链", systemImage: "desktopcomputer")
                Spacer()
                if store.probingToolchain {
                    ProgressView().scaleEffect(0.7)
                } else if let tc = store.toolchain {
                    Text(tc.summary)
                        .font(.caption)
                        .foregroundColor(tc.canCompileNative ? .green : .orange)
                } else {
                    Text("未检测").font(.caption).foregroundColor(.secondary)
                }
            }

            if let d = store.lastDecision {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: d.isCloud ? "cloud.fill" : "desktopcomputer")
                            .font(.caption)
                            .foregroundColor(d.isCloud ? .blue : .green)
                        Text("上次走的是：\(d.route.label)")
                            .font(.caption.weight(.medium))
                    }
                    Text(d.reason)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("编译怎么走")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("**顺序**：本机能编就本机编 → 本机失败且是偶发问题就重试一次 → 还是不行才推到 GitHub。")
                Text("**不会**把源码本身有错的活推上云 —— 那只会花额度换一个一模一样的报错。")
            }
        }
    }

    // MARK: - 五、说明

    private var aboutSection: some View {
        Section {
            if store.signedIn {
                Button("退出登录", role: .destructive) {
                    showSignOutConfirm = true
                }
            }
        } header: {
            Text("关于")
        } footer: {
            Text("令牌用 AES-GCM 加密后只存在这台手机上，密钥与设备绑定 —— 换机或还原备份后需要重新登录。上传的只是你让它编译的那些文件，不会上传聊天记录或其它数据。")
        }
    }
}

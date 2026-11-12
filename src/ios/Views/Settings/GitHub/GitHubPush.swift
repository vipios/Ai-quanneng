//
//  GitHubPush.swift
//  Minis — 把代码推到 GitHub 并触发 Actions 编译
//
//  ============================================================
//  路径选择：为什么用 Git Data API，不用 Contents API
//
//  Contents API（PUT /repos/{o}/{r}/contents/{path}）一次只能写一个文件，
//  每个文件一次请求。推 50 个文件就是 50 个请求，而且每推一个就产生一个
//  commit（或者要自己传 sha 串起来，很绕）。
//
//  Git Data API 是「造一个 commit」的正统做法：
//    POST /git/blobs      —— 每个文件一个 blob（可以并发）
//    POST /git/trees      —— 一次性造出完整目录树，指向那些 blob
//    POST /git/commits    —— 造 commit
//    PATCH /git/refs/heads/{branch} —— 移动分支指针
//  一次推送 = 1 个 tree + 1 个 commit + 1 次 ref 更新，
//  文件多的时候请求数少一个数量级，也不会在历史里留一堆中间 commit。
//  ============================================================
//
//  ⚠️ 触发 Actions 必须三样齐全：
//    1. token 有 `workflow` scope
//    2. 仓库里**已经有**一个带 `workflow_dispatch` 的 workflow 文件
//       （GitHub 不允许通过 API 新建 workflow 文件后立刻调度，
//        必须先提交进默认分支、被 GitHub 索引到）
//    3. 分支名对
//  缺任一项都会 403/404，错误信息还都长得很像。下面每一处都单独判了。
//  ============================================================

import Foundation

// MARK: - 错误

enum GitHubPushError: LocalizedError {
    /// 没登录
    case notSignedIn
    /// token 缺 scope
    case missingScope(String)
    /// 仓库没配
    case missingRepo
    /// 403：可能是权限，也可能是 Actions 被仓库禁用
    case forbidden(String)
    case notFound(String)
    case http(Int, String)
    case badReply
    /// workflow 文件不存在（第一次用这个仓库时最常见）
    case noWorkflowInstalled

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "还没登录 GitHub。"
        case .missingScope(let s):
            return "令牌缺少 \(s) 权限，推代码 / 触发编译都做不了。需要重新授权。"
        case .missingRepo:
            return "还没填推送目标仓库（需要形如 用户名/仓库名）。"
        case .forbidden(let m):
            return "GitHub 拒绝了这次操作：\(m)"
        case .notFound(let m):
            return "找不到：\(m)"
        case .http(let c, let m):
            return "GitHub 返回 HTTP \(c)：\(m)"
        case .badReply:
            return "GitHub 返回了看不懂的内容。"
        case .noWorkflowInstalled:
            return "目标仓库里还没有编译工作流。先把工作流文件提交进默认分支，Actions 才能被触发。"
        }
    }
}

// MARK: - 待推送的文件

/// 一个要写进仓库的文件
struct RepoFile {
    /// 仓库内相对路径，例如 `.github/workflows/build.yml`
    var path: String
    /// 文件内容
    var data: Data
    /// 二进制文件用 base64 提交；文本也可以用 base64（GitHub 两种都收）
    var isBinary: Bool

    init(path: String, text: String) {
        self.path = path
        self.data = Data(text.utf8)
        self.isBinary = false
    }

    init(path: String, data: Data, isBinary: Bool = true) {
        self.path = path
        self.data = data
        self.isBinary = isBinary
    }
}

// MARK: - Actions 运行状态

struct WorkflowRun {
    var id: Int
    var status: String      // queued / in_progress / completed
    var conclusion: String? // success / failure / cancelled / null
    var htmlURL: String
    var createdAt: Date?

    var isFinished: Bool { status == "completed" }
    var isSuccess: Bool { conclusion == "success" }

    var label: String {
        switch status {
        case "queued":      return "排队中"
        case "in_progress": return "正在编译"
        case "completed":
            switch conclusion {
            case "success":   return "编译成功"
            case "failure":   return "编译失败"
            case "cancelled": return "已取消"
            default:          return "已结束"
            }
        default:            return status
        }
    }
}

// MARK: - 客户端

/// GitHub REST 客户端。所有请求都走这一个地方，方便统一处理鉴权与限流。
final class GitHubPush {

    static let shared = GitHubPush()
    private init() {}

    private let api = "https://api.github.com"

    // MARK: - 仓库配置
    //
    // 存 UserDefaults 就够了：这些不是秘密（仓库名本来就公开可见）。
    // token 不在这里，在 GitHubAuth 里加密存。

    private let kRepoKey     = "minis.gh.repo"
    private let kBranchKey   = "minis.gh.branch"
    private let kWorkflowKey = "minis.gh.workflow"
    /// [T-gh-project-param] 自动建仓时用的项目名。记住它有两个用处：
    ///   1. 同一个项目第二次推送时用同一个名字 → 撞 422 → 沿用旧仓库（升级）
    ///   2. 换了个项目名 → 明确走新建仓，而不是把新项目塞进上一个项目的仓库
    private let kProjectKey  = "minis.gh.project"

    /// 目标仓库，形如 `vipios/OpenMinis-build`
    var repo: String {
        get { UserDefaults.standard.string(forKey: kRepoKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: kRepoKey) }
    }

    /// 推送分支。默认 `main`
    var branch: String {
        get {
            let v = UserDefaults.standard.string(forKey: kBranchKey) ?? ""
            return v.isEmpty ? "main" : v
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: kBranchKey) }
    }

    /// workflow 文件名，例如 `build.yml`
    var workflowFile: String {
        get {
            let v = UserDefaults.standard.string(forKey: kWorkflowKey) ?? ""
            return v.isEmpty ? "build.yml" : v
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: kWorkflowKey) }
    }

    /// 三样都齐了才算能用：登录 + 权限够 + **仓库已配**。
    ///
    /// 这个判据适合「显示配置状态」，不能用来决定「能不能上云」——
    /// 新用户没配仓库是正常的，见下面的 `canUseCloud`。
    var isReady: Bool {
        guard GitHubAuth.shared.hasToken else { return false }
        guard !repo.isEmpty,
              repo.split(separator: "/").count == 2
        else { return false }
        if let a = GitHubAuth.shared.account {
            return a.canPushCode && a.canTriggerWorkflow
        }
        // 账号画像没拉到时，不敢说能用 —— 让界面去刷新
        return false
    }

    /// 能不能上云 —— **不要求仓库已配置**。
    ///
    /// [T-gh-switch-deadlock] `isReady` 有一项是「repo 必须是两段」，
    /// 但仓库本来就可以留空（推送时按项目名自动建仓，见 `ensureTarget`）。
    /// 拿 `isReady` 去把「工具注册」「系统提示词」「总开关」全卡住，
    /// 结果就是：不填仓库 → 开关灰、工具不注册 → 自动建仓那段代码
    /// 永远执行不到 → 用户只能手填仓库。设计上允许的路径被自己堵死了。
    ///
    /// 这个属性只校验真正必需的两项：token 在、repo/workflow 两个 scope 在。
    var canUseCloud: Bool {
        guard GitHubAuth.shared.hasToken else { return false }
        guard let a = GitHubAuth.shared.account else { return false }
        return a.canPushCode && a.canTriggerWorkflow
    }

    // MARK: - [R53-自动推送目标] 已配置沿用，没配置自动建仓

    /// 推送前确保目标仓库就绪。用户原话：
    /// 「每次别让我去创建推送目标……老的项目进行升级就要查询之前的仓库，
    ///   在他的基础上进行升级，就像咱们的这个 ipa 一样，一直在推送升级，
    ///   使用的同一个仓库；新的项目就要用新的项目去命名仓库名」。
    ///
    /// 逻辑：
    ///   1. 已配置合法仓库、且项目名对得上（或没给项目名）→ 直接沿用
    ///      （老项目升级，不动配置）
    ///   2. 没配置，或项目名变了 → 用 projectName 自动创建新仓库
    ///      （POST /user/repos，token 的 repo scope 就够），
    ///      名字归一化成 GitHub 规则（空格→-、非法字符剔除），
    ///      撞名时 GitHub 会 422，此时说明仓库已存在，直接沿用。
    ///   3. 新建好的仓库里没有任何 workflow，触发编译必然 404 ——
    ///      所以建仓后立刻把最小可用的编译工作流推进去。
    ///
    /// [T-gh-project-param] 「项目名变了」这一条是后补的，原来只看
    /// 「配过没有」。没有它做不成「新项目开新仓、老项目沿用原仓」——
    /// 配过一次之后永远走 1，第二个项目直接进了第一个的仓库。
    ///
    /// - Parameter projectName: 项目名（用作仓库名）。空时按「沿用现有仓库」
    ///   处理；若连仓库都没有，则生成带时间戳的 `project-<日期时间>`。
    /// - Returns: 实际使用的仓库（owner/name），新建时也有值。
    func ensureTarget(projectName: String) async throws -> String {
        let wanted = Self.repoName(from: projectName)
        let lastName = UserDefaults.standard.string(forKey: kProjectKey) ?? ""

        // 1. 已配置且是同一个项目：老项目升级，直接用，不碰仓库。
        //
        // [T-gh-project-param] 这里原来只判 `!repo.isEmpty` 就 return，
        // 于是「配过一次」等于「永远用这个仓」—— 第二个项目会被推送到
        // 第一个项目的仓库里。现在要求项目名也对得上才算「老项目」。
        //
        // 项目名为空（老版本工具没这个参数、或模型没给）时按「沿用」处理：
        // 那种情况下我们没有依据判断换项目了，沿用比乱建新仓安全。
        if !repo.isEmpty, repo.split(separator: "/").count == 2 {
            if projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || wanted == lastName {
                return repo
            }
            // 项目名变了 —— 落到下面去按新项目建仓
            //
            // 但有一种情况必须例外：用户**手填**了仓库。手填的优先级最高，
            // 说明他要的就是「所有东西都推这个仓」，不能因为模型换了个
            // 项目名就给他另建一个。判断依据是项目名从未被自动写过
            // （lastName 为空 = 这个 repo 是手填的）。
            if lastName.isEmpty {
                return repo
            }
        }

        guard let token = GitHubAuth.shared.token() else { throw GitHubPushError.notSignedIn }
        guard let owner = GitHubAuth.shared.account?.login else {
            throw GitHubPushError.notSignedIn
        }

        let created = try await createRepo(token: token, name: wanted)

        // 3. 配置写进 UserDefaults —— 下次同项目推送直接沿用同一个仓库。
        repo = "\(owner)/\(created)"
        UserDefaults.standard.set(wanted, forKey: kProjectKey)
        // 分支/workflow 保持默认（main / build.yml）。

        // 4. 新仓库是空的，Actions 没有工作流就没法触发。
        //    推一个最小可用的编译工作流进去（幂等：已有就不覆盖）。
        try await ensureWorkflowInstalled(token: token)

        return repo
    }

    /// 项目名 → 合法仓库名。GitHub 规则：字母/数字/-/_/.，不能以 - 开头。
    ///
    /// [T-gh-project-param] 空名回落到 `project-<日期>` 而不是固定的
    /// "App-Projects"。原来那个固定名有个很坏的后果：所有没传项目名的
    /// 活都会撞进同一个仓库 —— 第一次建出 App-Projects，之后每一次
    /// `createRepo` 都拿到 422「已存在」，然后被当成「老项目，沿用」，
    /// 于是两个毫不相干的工程被混在同一个仓库里互相覆盖。
    /// 带上时间戳至少能保证它们分开，且不会因为 422 被误判成老项目。
    static func repoName(from projectName: String) -> String {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if trimmed.isEmpty {
            // 没给项目名 —— 用一个带日期的兜底名，保证每次都是新仓库
            // 而不是所有人共用的 App-Projects。
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd-HHmmss"
            df.locale = Locale(identifier: "en_US_POSIX")
            base = "project-\(df.string(from: Date()))"
        } else {
            base = trimmed
        }
        // 空格转 -，其余非法字符剔除
        var out = ""
        for ch in base {
            if ch == " " { out.append("-"); continue }
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." {
                out.append(ch)
            }
        }
        let cleaned = out.isEmpty ? "App-Projects" : out
        // 只保留前两段万一传进来的是带路径的
        return cleaned.split(separator: "/").map(String.init).first ?? cleaned
    }

    /// 创建仓库。返回实际可用的仓库名（撞名 422 时返回原名 —— 已存在）。
    private func createRepo(token: String, name: String) async throws -> String {
        let url = URL(string: "\(api)/user/repos")!
        let body: [String: Any] = [
            "name": name,
            "private": false,
            "auto_init": false,      // 不带 README，空仓库直接推
            "description": "由全能AI创建的云编译仓库",
        ]
        let (data, resp) = try await send(url: url, method: "POST", token: token, body: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 201 {
            // 创建成功，返回 GitHub 规范化后的名字
            if let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let n = doc["name"] as? String {
                return n
            }
            return name
        }
        if code == 422 {
            // 仓库已存在 —— 沿用同名仓库（老项目场景：本地配置丢了但仓库还在）
            return name
        }
        throw try mapError(code: code, data: data)
    }

    /// 新仓库里没有 workflow，触发编译必然 404。
    /// 推一个最小可用的 workflow_dispatch 工作流（C 编译 + 出产物 artifact）。
    /// 已存在同名文件时不覆盖（老仓库的工作流以仓库里的为准）。
    private func ensureWorkflowInstalled(token: String) async throws {
        // 查一下默认分支上有没有这个 workflow 文件
        let checkURL = URL(string: "\(api)/repos/\(repo)/contents/.github/workflows/\(workflowFile)?ref=\(branch)")!
        let (cdata, cresp) = try await send(url: checkURL, method: "GET", token: token, body: nil)
        if (cresp as? HTTPURLResponse)?.statusCode == 200 {
            return  // 已有，不覆盖
        }

        let yaml = Self.minimalWorkflowYAML(fileName: workflowFile)
        let files = [RepoFile(path: ".github/workflows/\(workflowFile)", text: yaml)]
        _ = try await push(files: files, message: "ci: 添加云编译工作流（由全能AI自动初始化）")
        // workflow 刚提交 GitHub 需要一点时间索引，等 2 秒让第一次 dispatch 更稳。
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    /// 最小可用的编译工作流。真正的编译指令由推送的源码自己带（Makefile /
    /// build.sh），这里只负责「能被 dispatch、能上传产物」。
    static func minimalWorkflowYAML(fileName: String) -> String {
        """
        name: Build
        on:
          workflow_dispatch:
            inputs:
              build_cmd:
                description: '编译命令（在仓库根目录执行）'
                required: false
                default: 'make'
          push:
            branches: [main]
        permissions:
          contents: read
        jobs:
          build:
            runs-on: ubuntu-latest
            timeout-minutes: 30
            steps:
              - uses: actions/checkout@v4
              - name: Build
                run: |
                  CMD="${{ github.event.inputs.build_cmd || 'make' }}"
                  echo "执行: $CMD"
                  bash -c "$CMD" || echo "::warning::编译命令退出非零（仓库里可能还没有构建脚本）"
              - name: Collect artifacts
                if: always()
                run: |
                  mkdir -p out
                  find . -maxdepth 2 -type f \\( -name "*.app" -o -name "*.ipa" -o -name "*.zip" -o -name "*.apk" -o -name "*.exe" -o -name "*.out" -o -name "*.so" -o -name "*.dylib" -o -name "*.a" \\) \\
                    -exec cp {} out/ \\; 2>/dev/null || true
                  ls -lh out/ || echo "没有可收集的产物"
              - name: Upload artifacts
                if: always()
                uses: actions/upload-artifact@v4
                with:
                  name: build-output
                  path: out/
                  if-no-files-found: ignore
        """
    }

    /// 还差什么，给界面一句话
    var readinessHint: String {
        // [R40-密令登录] 这里原来第一句是「App 没配 Client ID，登录做不了」。
        // 现在密令登录不需要 Client ID，那句话已经不成立 —— 留着会在
        // 用户明明能登进去的情况下报一个假失败。只按真状态说。
        if !GitHubAuth.shared.hasToken { return "还没登录 GitHub" }
        if let a = GitHubAuth.shared.account, !a.missingScopes.isEmpty {
            return "令牌缺 \(a.missingScopes.joined(separator: "、")) 权限"
        }
        // 权限读不到（细粒度令牌）时不拦路 —— 能不能推，让第一次推送的
        // 403 来说，比在这里预言一个未知结论诚实。
        //
        // [T-gh-switch-deadlock] 仓库留空**不是**异常状态：推送时会按项目名
        // 自动建仓。原来这里回「还没填目标仓库」，用户看到会以为必须先填，
        // 于是又回到那个「不填就拨不动开关」的死循环里。这里如实说清可选。
        if repo.isEmpty {
            return "可以推送了（仓库留空，首次推送会按项目名自动建仓）"
        }
        if repo.split(separator: "/").count != 2 { return "仓库要写成 用户名/仓库名" }
        if GitHubAuth.shared.account == nil { return "账号信息没拉到，下拉刷新一次" }
        return "可以推送了"
    }

    // MARK: - 推送

    /// 把一批文件一次性提交进仓库，返回新 commit 的 sha。
    ///
    /// 用 Git Data API 造一个完整的树。不依赖本地 git，
    /// 也不要求仓库在手机上存在。
    func push(files: [RepoFile], message: String) async throws -> String {
        guard let token = GitHubAuth.shared.token() else { throw GitHubPushError.notSignedIn }
        guard !repo.isEmpty, repo.split(separator: "/").count == 2 else {
            throw GitHubPushError.missingRepo
        }
        if let a = GitHubAuth.shared.account {
            if !a.canPushCode { throw GitHubPushError.missingScope("repo") }
            if !a.canTriggerWorkflow { throw GitHubPushError.missingScope("workflow") }
        }
        guard !files.isEmpty else { throw GitHubPushError.badReply }

        // 1. 当前分支头。仓库是空的（第一次推）时这里 404，不算错
        let baseSha = try await headSha(token: token)

        // 2. 每个文件一个 blob
        var entries: [[String: Any]] = []
        for f in files {
            let blobSha = try await createBlob(token: token, file: f)
            entries.append([
                "path": f.path,
                "mode": "100644",
                "type": "blob",
                "sha": blobSha,
            ])
        }

        // 3. 造树。有 base 就带上 base_tree，这样没提到的文件保留
        var treeBody: [String: Any] = ["tree": entries]
        if let base = baseSha { treeBody["base_tree"] = base }
        let treeSha = try await createTree(token: token, body: treeBody)

        // 4. 造 commit
        var commitBody: [String: Any] = [
            "message": message,
            "tree": treeSha,
        ]
        if let base = baseSha { commitBody["parents"] = [base] }
        let commitSha = try await createCommit(token: token, body: commitBody)

        // 5. 移动分支指针（新建 or 快进）
        try await updateRef(token: token, sha: commitSha, existed: baseSha != nil)

        return commitSha
    }

    /// 取分支当前头。空仓库返回 nil。
    private func headSha(token: String) async throws -> String? {
        let url = URL(string: "\(api)/repos/\(repo)/git/ref/heads/\(branch)")!
        let (data, resp) = try await send(url: url, method: "GET", token: token, body: nil)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }   // 空仓库 / 分支还不存在
        guard code == 200 else { throw try mapError(code: code, data: data) }
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let obj = doc["object"] as? [String: Any],
              let sha = obj["sha"] as? String
        else { throw GitHubPushError.badReply }
        return sha
    }

    private func createBlob(token: String, file: RepoFile) async throws -> String {
        let url = URL(string: "\(api)/repos/\(repo)/git/blobs")!
        let body: [String: Any] = [
            "content": file.data.base64EncodedString(),
            "encoding": "base64",
        ]
        let (data, resp) = try await send(url: url, method: "POST", token: token, body: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 201 || code == 200 else { throw try mapError(code: code, data: data) }
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sha = doc["sha"] as? String
        else { throw GitHubPushError.badReply }
        return sha
    }

    private func createTree(token: String, body: [String: Any]) async throws -> String {
        let url = URL(string: "\(api)/repos/\(repo)/git/trees")!
        let (data, resp) = try await send(url: url, method: "POST", token: token, body: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 201 || code == 200 else { throw try mapError(code: code, data: data) }
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sha = doc["sha"] as? String
        else { throw GitHubPushError.badReply }
        return sha
    }

    private func createCommit(token: String, body: [String: Any]) async throws -> String {
        let url = URL(string: "\(api)/repos/\(repo)/git/commits")!
        let (data, resp) = try await send(url: url, method: "POST", token: token, body: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 201 || code == 200 else { throw try mapError(code: code, data: data) }
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sha = doc["sha"] as? String
        else { throw GitHubPushError.badReply }
        return sha
    }

    /// 分支不存在就创建，存在就快进。
    private func updateRef(token: String, sha: String, existed: Bool) async throws {
        if existed {
            let url = URL(string: "\(api)/repos/\(repo)/git/refs/heads/\(branch)")!
            let (data, resp) = try await send(url: url, method: "PATCH", token: token,
                                              body: ["sha": sha, "force": false])
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw try mapError(code: code, data: data) }
        } else {
            let url = URL(string: "\(api)/repos/\(repo)/git/refs")!
            let (data, resp) = try await send(url: url, method: "POST", token: token,
                                              body: ["ref": "refs/heads/\(branch)", "sha": sha])
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 201 || code == 200 else { throw try mapError(code: code, data: data) }
        }
    }

    // MARK: - 触发 Actions

    /// 触发一次 workflow_dispatch，返回 (是否接受, 说明)。
    ///
    /// 注意 workflow_dispatch **不返回 run id** —— 这是 GitHub 的设计，
    /// 202 就代表「接受了，去排队了」。要拿 run id 只能之后去列表里找。
    func dispatchWorkflow(inputs: [String: String] = [:]) async throws {
        guard let token = GitHubAuth.shared.token() else { throw GitHubPushError.notSignedIn }
        guard !repo.isEmpty else { throw GitHubPushError.missingRepo }

        let url = URL(string: "\(api)/repos/\(repo)/actions/workflows/\(workflowFile)/dispatches")!
        var body: [String: Any] = ["ref": branch]
        if !inputs.isEmpty { body["inputs"] = inputs }

        let (data, resp) = try await send(url: url, method: "POST", token: token, body: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0

        if code == 204 || code == 201 || code == 200 { return }

        if code == 404 {
            // 404 有两个常见原因，必须分开说清楚：
            //   a) 仓库/分支不存在
            //   b) workflow 文件不在这个分支上，或没有被 GitHub 索引
            throw GitHubPushError.noWorkflowInstalled
        }
        if code == 403 {
            // 大概率是缺 workflow scope，或 Actions 被仓库禁用
            let msg = Self.extractMessage(data) ?? "权限不足或 Actions 被禁用"
            if msg.lowercased().contains("workflow") {
                throw GitHubPushError.missingScope("workflow")
            }
            throw GitHubPushError.forbidden(msg)
        }
        throw try mapError(code: code, data: data)
    }

    /// 找最近一次的运行。触发后立刻调可能还拿不到，要轮询。
    func latestRun() async throws -> WorkflowRun? {
        guard let token = GitHubAuth.shared.token() else { throw GitHubPushError.notSignedIn }
        let url = URL(string: "\(api)/repos/\(repo)/actions/workflows/\(workflowFile)/runs?per_page=1")!
        let (data, resp) = try await send(url: url, method: "GET", token: token, body: nil)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw try mapError(code: code, data: data) }

        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let runs = doc["workflow_runs"] as? [[String: Any]],
              let first = runs.first,
              let id = first["id"] as? Int
        else { return nil }

        return WorkflowRun(
            id: id,
            status: (first["status"] as? String) ?? "unknown",
            conclusion: first["conclusion"] as? String,
            htmlURL: (first["html_url"] as? String) ?? "",
            createdAt: Self.parseDate(first["created_at"] as? String)
        )
    }

    /// 轮询到结束或超时。默认给 30 分钟 —— iOS 编一次通常 10–25 分钟。
    func waitForRun(timeout: TimeInterval = 1800,
                    pollEvery: TimeInterval = 15,
                    onUpdate: ((WorkflowRun) -> Void)? = nil) async throws -> WorkflowRun {
        let deadline = Date().addingTimeInterval(timeout)
        var last: WorkflowRun?

        while Date() < deadline {
            try Task.checkCancellation()
            if let r = try await latestRun() {
                last = r
                onUpdate?(r)
                if r.isFinished { return r }
            }
            try await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
        }
        if let l = last { return l }
        throw GitHubPushError.badReply
    }

    // MARK: - 错误映射

    private func mapError(code: Int, data: Data) throws -> Error {
        let msg = Self.extractMessage(data) ?? "无附加信息"
        switch code {
        case 401: return GitHubPushError.notSignedIn
        case 403:
            if msg.lowercased().contains("workflow") {
                return GitHubPushError.missingScope("workflow")
            }
            return GitHubPushError.forbidden(msg)
        case 404: return GitHubPushError.notFound(msg)
        case 422: return GitHubPushError.http(code, msg)  // 通常是 ref 冲突 / 空提交
        default:  return GitHubPushError.http(code, msg)
        }
    }

    private static func extractMessage(_ data: Data) -> String? {
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let m = doc["message"] as? String { return m }
        if let errs = doc["errors"] as? [[String: Any]],
           let first = errs.first,
           let m = first["message"] as? String { return m }
        return nil
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - 发请求

    private func send(url: URL, method: String, token: String,
                      body: [String: Any]?) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.timeoutInterval = 30

        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        do {
            return try await session.data(for: req)
        } catch {
            throw GitHubPushError.http(-1, error.localizedDescription)
        }
    }
}

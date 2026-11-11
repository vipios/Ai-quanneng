import Foundation

// MARK: - github_cloud_build 的执行体  [T-minis-gh-fallback-switch]
//
// 这是三道门里的第三道。前两道（schema 注册、system prompt 段落）是
// 「让模型不知道」，这一道是「就算它知道了也做不成」。
//
// 为什么非要有这层：工具列表是每轮重算的，执行队列不是。用户在工具调用
// 已经排队、还没轮到的时候把开关关掉 —— 那一次调用必须失败，不能因为
// 「请求发出时开关是开的」就照推代码到人家的仓库。
//
// 另外这层还负责一件前两道管不了的事：**把模型的意图翻成仓库里真实的字节**。
// 模型给的是沙箱内的绝对路径（/var/ai/workspace/foo.c），
// GitHub 需要的是仓库内相对路径 + 内容。中间要做读取、大小检查、二进制判定。
//
// 参数给错时的报错都写成「你能照着改」的形式 —— 工具出错后模型会读这段字
// 决定下一步，写「invalid parameter」等于让它瞎猜。

enum GitHubCloudBuildTool {

    static let name = "github_cloud_build"

    /// 单次推送的体积上限。
    ///
    /// GitHub 走 base64 内联 blob 时单个约 40MB 就顶了，但这里卡到 8MB
    /// 是因为手机上传输与 base64 编码都要吃内存，而且真正该走云编译的
    /// 源码工程本来也不会这么大。超了让用户改用本地 git push。
    static let maxTotalBytes = 8 * 1024 * 1024

    /// 一个待推送文件。
    private struct ParsedFile {
        var repoPath: String
        var sandboxPath: String
        var isBinary: Bool
    }

    // MARK: - 入口

    /// 执行一次云编译兜底。
    ///
    /// 返回 (给模型看的文字, 是否成功)。成功时文字里带 run id 与链接，
    /// 模型会把它转述给用户 —— 所以这里要写人能读懂的话，不是 JSON dump。
    static func execute(args: [String: Any]) async -> (output: String, success: Bool) {
        // ── 门禁 ──────────────────────────────────────────────
        guard AgentToolSwitch.isToolEnabled(name) else {
            return (Self.disabledMessage, false)
        }
        guard GitHubAuth.shared.hasToken else {
            return ("Error: 还没登录 GitHub。让用户到「设置 → 存储 → GitHub 账号」登录后再试。不要重试本工具。", false)
        }
        // [R53-自动推送目标] 不再要求预先手动配置仓库：
        // 已配置 → 沿用旧仓库（老项目一直升级同一个仓）；
        // 没配置 → 用项目名自动建仓 + 装好编译工作流。
        // 项目名从可选参数取，模型不传就回落默认名。
        let projectName = (args["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            _ = try await GitHubPush.shared.ensureTarget(projectName: projectName)
        } catch let e as GitHubPushError {
            return ("Error: 准备推送目标失败 —— \(e.errorDescription ?? "未知错误")。"
                    + "把这个原因告诉用户，不要重试。", false)
        } catch {
            return ("Error: 准备推送目标失败 —— \(error.localizedDescription)。不要重试。", false)
        }

        // ── 参数 ──────────────────────────────────────────────
        guard let filesRaw = args["files"] as? String, !filesRaw.isEmpty else {
            return ("Error: 缺 files 参数。要传一个 JSON 数组，每项形如 "
                    + #"{"path":"src/main.c","source":"/var/ai/workspace/main.c"}"# + "。", false)
        }
        guard let reason = (args["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else {
            return ("Error: 缺 reason 参数。要写清本机为什么编不出来（失败的命令 + 第一行报错）。"
                    + "这段会显示给用户。", false)
        }

        let parsed: [ParsedFile]
        do {
            parsed = try parseFiles(filesRaw)
        } catch let e as BuildArgError {
            return ("Error: \(e.message)", false)
        } catch {
            return ("Error: files 解析失败 —— \(error.localizedDescription)", false)
        }

        // ── 读字节 ────────────────────────────────────────────
        var repoFiles: [RepoFile] = []
        var total = 0
        for f in parsed {
            guard let data = readSandboxFile(f.sandboxPath) else {
                return ("Error: 读不到 \(f.sandboxPath)。先用 shell_execute 确认这个文件存在"
                        + "（`ls -l \(f.sandboxPath)`），再重试。", false)
            }
            total += data.count
            if total > maxTotalBytes {
                return ("Error: 要推的总大小超过 \(maxTotalBytes / 1024 / 1024)MB。"
                        + "云编译不该用来搬大数据集 —— 只推源码与构建脚本，"
                        + "或者让用户改用本地 git push。", false)
            }
            repoFiles.append(RepoFile(path: f.repoPath, data: data, isBinary: f.isBinary))
        }

        // ── 推送 ──────────────────────────────────────────────
        let commitMessage = (args["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? "Cloud build: \(parsed.count) file(s)\n\n\(reason)"

        var commitSha: String
        do {
            commitSha = try await GitHubPush.shared.push(files: repoFiles, message: commitMessage)
        } catch let e as GitHubPushError {
            return ("Error: 推送失败 —— \(e.errorDescription ?? "未知错误")", false)
        } catch {
            return ("Error: 推送失败 —— \(error.localizedDescription)", false)
        }

        // ── 触发 workflow ─────────────────────────────────────
        let inputs = parseInputs(args["inputs"] as? String)
        do {
            try await GitHubPush.shared.dispatchWorkflow(inputs: inputs)
        } catch let e as GitHubPushError {
            // 404 是这里最需要说清的一种：代码已经推上去了，但 workflow 没跑起来。
            // 三种原因（仓库名错 / yml 不在默认分支 / 未被索引）返回的都是 404，
            // 模型没法自己分辨，所以这里把三种可能都摊开。
            if case .noWorkflowInstalled = e {
                return ("""
                Error: 代码已经推上去了（commit \(commitSha.prefix(7))），但 workflow 触发不了。
                原因通常是这三个之一：
                1. 仓库名填错了 —— 当前是 \(GitHubPush.shared.repo)
                2. \(GitHubPush.shared.workflowFile) 不在默认分支（\(GitHubPush.shared.branch)）上
                3. 文件刚提交，GitHub 还没索引到（等一两分钟）
                把这三条告诉用户，让他们在仓库里确认。不要重试 —— 重试同样会 404。
                """, false)
            }
            return ("Error: 代码推上去了（commit \(commitSha.prefix(7))），但触发 workflow 失败 —— "
                    + (e.errorDescription ?? "未知错误"), false)
        } catch {
            // 必须留这个兜底 catch。
            //
            // 上面那个 `catch let e as GitHubPushError` 是**带类型筛选**的，
            // Swift 不认为它把 Error 捕获穷尽了 —— 编译器只认裸 `catch`
            // 或者能证明覆盖全部 Error 类型的分支。缺它就会报：
            //   error: errors thrown from here are not handled because the
            //          enclosing catch is not exhaustive
            // 这一点和 100~106 行那次推送不同：那次我写了兜底，这次漏了。
            //
            // 实际能走到这里的是 dispatchWorkflow 内部抛出的非 GitHubPushError
            // （网络层直接把 URLError 透出来时）。语义上等于推送成功、触发失败。
            return ("Error: 代码推上去了（commit \(commitSha.prefix(7))），但触发 workflow 失败 —— "
                    + error.localizedDescription, false)
        }

        // ── 等一小会儿拿到 run ─────────────────────────────────
        //
        // workflow_dispatch 返回 202 只代表「收到了」，不给 run id。
        // 立刻查 latestRun 往往还是上一次的旧 run（或 nil），因为新 run
        // 还没出现在列表里。所以这里做一次短轮询：最多等 30 秒，
        // 拿到一个刚创建的 run 就收工；超时就如实说「已提交，去看列表」。
        var run: WorkflowRun?
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let r = try? await GitHubPush.shared.latestRun() {
                // 只认 queued / in_progress 的，已完成的必定是旧 run
                if !r.isFinished {
                    run = r
                    break
                }
            }
        }

        // ── 回报 ──────────────────────────────────────────────
        var out = "已推送到 \(GitHubPush.shared.repo)（\(GitHubPush.shared.branch) 分支），"
            + "commit \(commitSha.prefix(7))，共 \(parsed.count) 个文件。\n"
            + "触发原因记录：\(reason)\n"
        if let r = run {
            out += "云端任务已排队：\(r.label)\n\(r.htmlURL)\n"
            + "告诉用户这个链接可以看实时日志，构建完成后在页面的 Artifacts 里下载产物。"
        } else {
            out += "workflow 已接受，但 30 秒内还没在运行列表里出现（正常，有时要等一两分钟）。\n"
            + "让用户到 https://github.com/\(GitHubPush.shared.repo)/actions 自己看。"
            + "不要重复触发 —— 会产生重复的构建。"
        }
        return (out, true)
    }

    // MARK: - 读沙箱文件
    //
    // `/var/ai/...` 是 **iSH 内部**的路径。App 进程直接拿这个字符串去
    // FileManager 是读不到的 —— 那几个目录是 iSH rootfs 里的挂载点。
    // 必须先经 RootfsManager 映射成宿主路径。
    //
    // 顺序照抄 ModelUseOffloadBridge.readImageFile：先试 rootfs 映射，
    // 再试字面路径。后者不是冗余 —— /tmp 下我们自己写的临时文件
    // （内联 content 分支落的盘）就在宿主侧，映射后反而找不到。
    private static func readSandboxFile(_ linuxPath: String) -> Data? {
        let hostPath = RootfsManager.shared.dataPath
            .appendingPathComponent(linuxPath).path
        if let d = FileManager.default.contents(atPath: hostPath) { return d }
        if let d = FileManager.default.contents(atPath: linuxPath) { return d }
        return nil
    }

    // MARK: - 参数解析

    private struct BuildArgError: Error { let message: String }

    /// 解析 files 参数。
    ///
    /// 接受两种写法，因为模型两种都可能给：
    ///   [{"path":"a.c","source":"/var/ai/workspace/a.c"}]        ← 推荐
    ///   [{"path":"a.c","content":"..."}]                            ← 小文件直接内联
    ///
    /// 只收 path + source 的话，模型有时会把整个文件内容塞进 source 字段；
    /// 只收 content 的话，大文件必然把上下文撑爆。两种都支持，各走各的路。
    private static func parseFiles(_ raw: String) throws -> [ParsedFile] {
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw BuildArgError(message: "files 不是合法的 JSON 数组。要形如 "
                                + #"[{"path":"src/main.c","source":"/var/ai/workspace/main.c"}]"#)
        }
        guard !arr.isEmpty else {
            throw BuildArgError(message: "files 是空数组，没有东西可推。")
        }

        var out: [ParsedFile] = []
        for (i, item) in arr.enumerated() {
            guard let repoPath = (item["path"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !repoPath.isEmpty
            else {
                throw BuildArgError(message: "files[\(i)] 缺 path（仓库内相对路径，如 src/main.c）。")
            }
            // 仓库内路径不允许绝对路径或 ..，否则会推到仓库外面去
            if repoPath.hasPrefix("/") || repoPath.contains("..") {
                throw BuildArgError(message: "files[\(i)].path 必须是仓库内的相对路径，"
                                    + "不能以 / 开头也不能含 ..（收到 \(repoPath)）。")
            }

            let isBinary = (item["binary"] as? Bool) ?? false

            if let source = (item["source"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
                out.append(ParsedFile(repoPath: repoPath, sandboxPath: source, isBinary: isBinary))
                continue
            }

            // 内联内容分支：落到临时文件，后面统一按路径读。
            // 这样上面的体积检查、缺失检查全都只写一份。
            if let content = item["content"] as? String {
                let tmp = NSTemporaryDirectory() + "ghpush-" + UUID().uuidString
                guard (try? content.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else {
                    throw BuildArgError(message: "files[\(i)] 的内联内容写不出去。")
                }
                out.append(ParsedFile(repoPath: repoPath, sandboxPath: tmp, isBinary: isBinary))
                continue
            }

            throw BuildArgError(message: "files[\(i)] 既没有 source 也没有 content。"
                                + "source 是沙箱内绝对路径（推荐），content 是文件正文。")
        }
        return out
    }

    /// inputs 参数（workflow_dispatch 的输入），宽容解析。
    ///
    /// 模型可能给 JSON 字符串，也可能干脆给个字典 —— 后者进不来（工具参数
    /// 只能声明标量），所以只处理字符串。解析不了就当没给，不因此让整次
    /// 推送失败 —— 代码已经推上去了，用默认参数跑一次比直接报错强。
    private static func parseInputs(_ raw: String?) -> [String: String] {
        guard let raw, !raw.isEmpty,
              let d = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
            else if let n = v as? NSNumber { out[k] = n.stringValue }
        }
        return out
    }

    /// 开关关着时的拒绝文案。
    ///
    /// 措辞和 `AIChatViewModel.toolsDisabledMessage` 保持一致（不直接引用它：
    /// 那是个 @MainActor 类型上的静态属性，本 enum 在非隔离上下文里也会被调，
    /// 读它要跨 actor，为一个固定字符串不值得）。两处文字必须一样 ——
    /// 模型看到「工具被关了」应该是同一句话，不然它会当成两种故障去试两种补救。
    static let disabledMessage =
        "Error: This tool is turned off in the app's settings. "
        + "Tell the user they can enable it there; do not retry."
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

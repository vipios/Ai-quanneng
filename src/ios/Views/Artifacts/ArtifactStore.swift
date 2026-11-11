//
//  ArtifactStore.swift
//  Minis — 「全部产物」的数据层
//
//  ============================================================
//  这是什么
//
//  侧栏「全部产物」那一栏背后的模型：把所有会话产出过的文件
//  按「会话标题 → 文件」组织成两层的清单，供列表页展示、重命名、
//  删除、分享、跳回对应会话。
//
//  为什么不复用现有类型
//  ----------------------------------------------------------
//  App 里原本没有「产物」这个概念。`/var/minis/{workspace,attachments,
//  offloads}` 只是三个目录，谁产生的、属于哪个对话，代码里没有任何
//  记录。唯一可用的归属信息是**磁盘布局本身**：
//
//      Library/MinisChat/minis/<sessionId>/{workspace,attachments,offloads}/
//
//  也就是说 sessionId 是父目录名。所以「按对话标题给产物分组」这件事
//  不需要新的数据库列，只要把 sessionId 换回 ChatSession.title 即可。
//
//  取哪几个目录
//  ----------------------------------------------------------
//  workspace   —— 会话的工作区，agent 写脚本/数据/图表都落这里
//  attachments —— 上传的与生成的多媒体
//  offloads    —— 大输出的自动落地，也是产物
//
//  不含 browser/（截图缓存，噪音大）与 memory/（不是产物）。
//
//  性能
//  ----------------------------------------------------------
//  4700 会话的规模下不能每次进页面都全盘遍历，也不能在主线程上做
//  4700 次 `fileExists`。所以：
//    - 目录存在性检查、mtime 统计、列目录**全部**在后台一次做完；
//    - 缓存键是「会话 id 集合 + 每个会话目录的 mtime」，mtime 变了才重扫；
//    - 单个会话的目录最多列三层，不再递归到底。
//
//  Swift 6 并发
//  ----------------------------------------------------------
//  类标了 `@MainActor`，所以类里的 `static let` 默认也是 MainActor
//  隔离的 —— 后台任务读它就是编译错误。凡是后台要用的常量与工具函数
//  一律显式 `nonisolated`，`FileManager` 不跨 actor 传（在后台侧自己
//  取 `.default`），进出后台的值类型全部 `Sendable`。
//
//  ============================================================

import Foundation

// MARK: - 模型

/// 一个产物文件。
///
/// `Equatable` 按 `id`（= 绝对路径）比，rename 之后路径变了所以是一条新记录，
/// 这正是列表要的行为（旧行消失、新行出现）。
struct ArtifactItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String              // 绝对路径，天然唯一
    let url: URL
    let name: String            // 显示名（不含目录）
    let byteCount: Int64
    let modifiedAt: Date
    let kind: Kind
    /// 归属会话。nil = 找不到归属（例如 shared/ 下的跨会话文件）。
    let sessionId: String?

    enum Kind: String, Sendable {
        case image, video, audio, document, archive, code, data, other

        /// SF Symbol 名。列表左侧那个小图标用它。
        var symbol: String {
            switch self {
            case .image:    return "photo"
            case .video:    return "film"
            case .audio:    return "waveform"
            case .document: return "doc.text"
            case .archive:  return "shippingbox"
            case .code:     return "chevron.left.forwardslash.chevron.right"
            case .data:     return "tablecells"
            case .other:    return "doc"
            }
        }

        static func from(ext: String) -> Kind {
            switch ext.lowercased() {
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg":
                return .image
            case "mp4", "mov", "m4v", "avi", "mkv", "webm":
                return .video
            case "mp3", "m4a", "wav", "aac", "flac", "ogg":
                return .audio
            case "pdf", "doc", "docx", "txt", "md", "rtf", "pages", "epub":
                return .document
            case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "ipa", "apk", "deb":
                return .archive
            case "swift", "py", "js", "ts", "c", "h", "cpp", "m", "mm", "rs", "go",
                 "java", "kt", "sh", "bash", "zsh", "rb", "php", "lua", "pl", "sql",
                 "yaml", "yml", "toml":
                return .code
            case "csv", "tsv", "json", "xml", "plist", "db", "sqlite", "xlsx", "xls", "numbers":
                return .data
            default:
                return .other
            }
        }
    }

    /// 人看的体积，例如 "1.2 MB"。
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

/// 一个会话下的产物集合。`title` 是分组头要显示的文字。
struct ArtifactGroup: Identifiable, Equatable, Sendable {
    /// `sessionId`。
    let id: String
    /// 会话标题。空标题回落到「Untitled」。
    let title: String
    let items: [ArtifactItem]

    var newestAt: Date { items.first?.modifiedAt ?? .distantPast }

    /// 组内文件总体积，分组头右侧那行小字用。
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }

    var totalSizeText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

// MARK: - Store

/// 「全部产物」的数据源。单例，`@MainActor`，扫描在后台。
@MainActor
final class ArtifactStore: ObservableObject {
    static let shared = ArtifactStore()

    /// 扫描结果，按「最新修改时间倒序」的组，组内文件也按时间倒序。
    @Published private(set) var groups: [ArtifactGroup] = []
    /// 首次扫描是否已完成。false 时列表显示骨架，不显示「暂无产物」。
    @Published private(set) var hasLoaded = false
    @Published private(set) var isScanning = false

    private let logger = AppLogger(category: "Artifact")

    /// 缓存键：会话 id → 该会话目录的 mtime。任何一个变了就重扫。
    private var signature: [String: Date] = [:]

    /// 要收的会话级子目录。顺序不重要，但保持稳定便于调试。
    /// `nonisolated`：后台扫描要读它，而类的 `@MainActor` 会把普通 static 也隔离掉。
    nonisolated private static let scannedSubdirs = ["workspace", "attachments", "offloads"]

    /// 单个目录最多列几层。产物通常就在一层里，多留一层兜住 `workspace/project/`
    /// 这种分组写法，再深就不再往下走。
    nonisolated private static let maxDepth = 2

    /// `Library/MinisChat/minis`，与会话目录同一个基。后台也要读，故 nonisolated。
    nonisolated private static var persistentBase: URL {
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MinisChat/minis", isDirectory: true)
        }
        return lib.appendingPathComponent("MinisChat/minis", isDirectory: true)
    }

    // MARK: 扫描

    /// 重新扫描。`sessions` 用来把 sessionId 换成标题。
    ///
    /// - Parameter force: true 时忽略缓存，无条件重扫（下拉刷新用）。
    func refresh(sessions: [ChatSession], force: Bool = false) async {
        // 主线程上只做一次轻量投影：把 [ChatSession] 压成 [(id, 标题)]。
        // ChatSession 字段多，把这个数组整个带进后台既浪费拷贝量，也逼着
        // 后台任务去碰一个只该在 UI 侧用的类型。
        let pairs: [(id: String, title: String)] = sessions.map { ($0.id, $0.title ?? "") }
        let base = Self.persistentBase
        let subdirs = Self.scannedSubdirs
        let depthLimit = Self.maxDepth

        isScanning = true
        defer { isScanning = false }

        // 存在性检查 + mtime + 列目录，全部在后台一次做完。
        // 主线程不参与 —— 4700 次 stat 在主线程上就是一个肉眼可见的卡顿。
        let scan: ScanResult = await Task.detached(priority: .userInitiated) {
            Self.scan(pairs: pairs, base: base, subdirs: subdirs, maxDepth: depthLimit)
        }.value

        if !force, scan.signature == signature, hasLoaded {
            return    // 一个都没动过，跳过
        }

        var built: [ArtifactGroup] = []
        built.reserveCapacity(scan.itemsBySession.count)
        for (sid, items) in scan.itemsBySession {
            let raw = scan.titles[sid] ?? ""
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            built.append(ArtifactGroup(
                id: sid,
                title: title.isEmpty ? AppLocalized("Untitled") : title,
                items: items
            ))
        }
        built.sort { $0.newestAt > $1.newestAt }

        groups = built
        signature = scan.signature
        hasLoaded = true
        logger.info("[Artifact] groups=\(built.count) files=\(built.reduce(0) { $0 + $1.items.count })")
    }

    /// 后台扫描的返回值。一个结构体带三样东西，避免多次跨 actor 往返。
    private struct ScanResult: Sendable {
        var signature: [String: Date] = [:]
        var itemsBySession: [String: [ArtifactItem]] = [:]
        var titles: [String: String] = [:]
    }

    /// 全量扫描。`nonisolated` + `static`：不碰任何实例状态，纯粹按磁盘说话。
    nonisolated private static func scan(
        pairs: [(id: String, title: String)],
        base: URL,
        subdirs: [String],
        maxDepth: Int
    ) -> ScanResult {
        let fm = FileManager.default      // 在后台侧自己取，不跨 actor 传引用
        var out = ScanResult()
        out.signature.reserveCapacity(pairs.count)
        out.titles.reserveCapacity(pairs.count)

        for pair in pairs {
            let dir = base.appendingPathComponent(pair.id, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                continue   // 这个会话没有落盘目录，连签名都不记
            }
            out.signature[pair.id] = mtime(of: dir, fm: fm)
            out.titles[pair.id] = pair.title     // 手写赋值，不用 uniqueKeysWithValues

            var items: [ArtifactItem] = []
            for sub in subdirs {
                let subdir = dir.appendingPathComponent(sub, isDirectory: true)
                var subIsDir: ObjCBool = false
                guard fm.fileExists(atPath: subdir.path, isDirectory: &subIsDir),
                      subIsDir.boolValue else { continue }
                items += collect(in: subdir, sessionId: pair.id, depth: 0, maxDepth: maxDepth, fm: fm)
            }
            if !items.isEmpty {
                out.itemsBySession[pair.id] = items.sorted { $0.modifiedAt > $1.modifiedAt }
            }
        }
        return out
    }

    /// 列一个目录里的文件。`depth` 到上限后就不再往下走。
    nonisolated private static func collect(
        in dir: URL,
        sessionId: String,
        depth: Int,
        maxDepth: Int,
        fm: FileManager
    ) -> [ArtifactItem] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey
        ]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var out: [ArtifactItem] = []
        for e in entries {
            let vals = try? e.resourceValues(forKeys: Set(keys))
            if vals?.isSymbolicLink == true { continue }   // 跟随软链容易绕成死环

            if vals?.isDirectory == true {
                if depth + 1 < maxDepth {
                    out += collect(in: e, sessionId: sessionId, depth: depth + 1,
                                   maxDepth: maxDepth, fm: fm)
                }
                continue    // 到达层数上限的目录本身不当产物，只跳过
            }

            let size = Int64(vals?.fileSize ?? 0)
            // 空文件不当产物：agent 偶尔会 touch 一个占位文件。
            guard size > 0 else { continue }

            out.append(ArtifactItem(
                id: e.path,
                url: e,
                name: e.lastPathComponent,
                byteCount: size,
                modifiedAt: vals?.contentModificationDate ?? .distantPast,
                kind: ArtifactItem.Kind.from(ext: e.pathExtension),
                sessionId: sessionId
            ))
        }
        return out
    }

    /// 目录 mtime。拿不到就退回 epoch（会被当成「变过」，宁可多扫一次）。
    nonisolated private static func mtime(of url: URL, fm: FileManager) -> Date {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: 查询

    /// 某个会话的产物组。跳回会话前确认它还有产物时用。
    func group(for sessionId: String) -> ArtifactGroup? {
        groups.first { $0.id == sessionId }
    }

    /// 模糊搜索。命中「会话标题」时整组带出；否则只留下文件名命中的条目。
    ///
    /// 大小写与全半角不敏感，多关键词按 OR 处理 —— 与侧栏会话搜索
    /// （`SearchKeywords`）保持同一套语义，用户不该在两处遇到两种规则。
    func search(_ query: String) -> [ArtifactGroup] {
        let terms = SearchKeywords.terms(query)
        guard !terms.isEmpty else { return groups }

        var hits: [ArtifactGroup] = []
        for g in groups {
            if SearchKeywords.firstHit(in: g.title, terms: terms) != nil {
                hits.append(g)          // 对话名命中 → 这个对话的产物全要
                continue
            }
            let matched = g.items.filter { item in
                SearchKeywords.firstHit(in: item.name, terms: terms) != nil
            }
            if !matched.isEmpty {
                hits.append(ArtifactGroup(id: g.id, title: g.title, items: matched))
            }
        }
        return hits
    }

    // MARK: 写操作

    /// 改文件名。返回新 URL；失败时抛 `ArtifactError`，由调用方显示。
    @discardableResult
    func rename(_ item: ArtifactItem, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ArtifactError.emptyName }

        let ext = item.url.pathExtension
        // 用户没写扩展名时自动保留原扩展名，避免变成无类型文件。
        var dest = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if dest.pathExtension.isEmpty && !ext.isEmpty {
            dest = dest.appendingPathExtension(ext)
        }
        guard dest.path != item.url.path else { return item.url }   // 名字没变

        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else { throw ArtifactError.nameTaken }
        try fm.moveItem(at: item.url, to: dest)
        logger.info("[Artifact] rename \(item.name) → \(dest.lastPathComponent)")
        return dest
    }

    /// 删文件。删完顺手清掉因此变空的**子目录**，但不碰 workspace /
    /// attachments / offloads 这三层本身 —— 它们是会话目录的固定骨架，
    /// 删了之后 agent 下轮还要重新建。
    func delete(_ item: ArtifactItem) throws {
        try FileManager.default.removeItem(at: item.url)
        logger.info("[Artifact] delete \(item.name)")

        let parent = item.url.deletingLastPathComponent()
        let base = Self.persistentBase
        let parentName = parent.lastPathComponent
        guard !Self.scannedSubdirs.contains(parentName) else { return }  // 骨架层留着
        guard parent.path != base.path, parent.path.hasPrefix(base.path) else { return }

        if let left = try? FileManager.default.contentsOfDirectory(atPath: parent.path), left.isEmpty {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    /// 从当前缓存里移除一条，避免删完等重扫才消失。
    func dropFromCache(_ item: ArtifactItem) {
        groups = groups.compactMap { g in
            let left = g.items.filter { $0.id != item.id }
            return left.isEmpty ? nil : ArtifactGroup(id: g.id, title: g.title, items: left)
        }
    }

    /// 改名后把缓存里的那条就地替掉。
    func replaceInCache(_ old: ArtifactItem, with url: URL) {
        let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let new = ArtifactItem(
            id: url.path,
            url: url,
            name: url.lastPathComponent,
            byteCount: vals?.fileSize.map(Int64.init) ?? old.byteCount,
            modifiedAt: vals?.contentModificationDate ?? Date(),
            kind: ArtifactItem.Kind.from(ext: url.pathExtension),
            sessionId: old.sessionId
        )
        groups = groups.map { g in
            guard g.items.contains(where: { $0.id == old.id }) else { return g }
            let replaced = g.items.map { $0.id == old.id ? new : $0 }
                .sorted { $0.modifiedAt > $1.modifiedAt }
            return ArtifactGroup(id: g.id, title: g.title, items: replaced)
        }
    }
}

// MARK: - 错误

enum ArtifactError: LocalizedError {
    case emptyName
    case nameTaken

    var errorDescription: String? {
        switch self {
        case .emptyName: return AppLocalized("Name can't be empty")
        case .nameTaken: return AppLocalized("A file with that name already exists")
        }
    }
}

//
//  SettingsRowLabel.swift
//  Minis — 设置页行标题的稳定标识与显示
//
//  ============================================================
//  [R51-改名功能删除] 原来这两个符号和「长按/左滑改名」一起住在
//  SettingsRename.swift 里。删改名功能时把整文件删了，结果把
//  SettingsRowId / SettingsRowLabel 也带走了 —— 但设置页每行的
//  标题和图标都还在用它，编译直接 30 处 cannot find in scope。
//
//  所以这里把它们单独拎出来，只保留「显示标题」这一件事：
//  自定义名、改名弹窗、左滑手势、持久化全部不在了。
//  SettingsRowLabel 现在就是 Text(fallback)，不做任何查询。
//  ============================================================

import SwiftUI

// MARK: - 行标识

/// 设置页每一行的稳定 id。设置页用它定位某一行的标题（历史遗留
/// 自改名功能），现在主要用于 `SettingsRowLabel(.xxx, fallback:)`
/// 的标签参数。
enum SettingsRowId: String, CaseIterable {
    // AI 服务商
    case providers          = "providers"
    // [R65] 「添加 AI 中转站」从服务商页的加号菜单搬到了这里，
    // 位置就在「AI 服务商」下面，图标样式也跟它对齐。
    case addRelay           = "addRelay"
    case modelGroups        = "modelGroups"
    case tokenUsage         = "tokenUsage"
    // 设备管理
    case relayAdmin         = "relayAdmin"
    case relayRouter        = "relayRouter"
    // 外观
    case appearance         = "appearance"
    // 智能体运行时
    case agentTools         = "agentTools"
    case subAgents          = "subAgents"
    case skills             = "skills"
    // [R42] 说话模式
    case modes              = "modes"
    case soul               = "soul"
    case memory             = "memory"
    case mcpIntegrations    = "mcpIntegrations"
    case environmentVars    = "environmentVars"
    // 存储
    case storage            = "storage"
    case sharedFolders      = "sharedFolders"
    case mountedFolders     = "mountedFolders"
    case iCloudSync         = "iCloudSync"
    case backupRestore      = "backupRestore"
    case githubAccount      = "githubAccount"
    // 权限
    case permissions        = "permissions"
    case faceID             = "faceID"
    // 日志
    case logs               = "logs"
    // 版本和更新
    case version            = "version"
    case checkUpdate        = "checkUpdate"
    case updateSource       = "updateSource"
    // 关于
    case about              = "about"
    case privacyPolicy      = "privacyPolicy"
    case feedback           = "feedback"
}

// MARK: - 标题

/// 设置页的标题。用法 `SettingsRowLabel(.skills, fallback: "Skills")`。
///
/// [R51] 改名功能已删，这里不再查自定义名，直接显示 fallback 原文。
/// 保留这个 View 是为了不动 SettingsSheet / SelfUpdateSection 里
/// 几十处调用点的写法。
struct SettingsRowLabel: View {

    let id: SettingsRowId
    let fallbackKey: LocalizedStringKey

    init(_ id: SettingsRowId, fallback fallbackKey: LocalizedStringKey) {
        self.id = id
        self.fallbackKey = fallbackKey
    }

    var body: some View {
        Text(fallbackKey)
    }
}

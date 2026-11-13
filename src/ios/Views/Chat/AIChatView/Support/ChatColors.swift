//
//  ChatColors.swift
//  Minis - chat page (AIChatView)
//
//  ChatColors: the chat UI's color palette (system colors, light / dark).
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Color Palette (clean light theme)

enum ChatColors {
    /// 浅色 #f8f8f8，深色仍走 systemBackground。
    ///
    /// 原来是纯 `systemBackground`（浅色 = 纯白 255）。改成 248 是为了和抽屉
    /// 底色（`SessionDrawer.paper`）完全对齐 —— 参照图里卡片和抽屉是同一个
    /// #f8f8f8，两者只靠卡片那道阴影分界，不存在「白纸压在灰纸上」的层次。
    ///
    /// 只动浅色：深色模式下 systemBackground 是接近纯黑，248 那套换算过去
    /// 没有意义，保持系统值。
    static let background = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.systemBackground
            : UIColor(red: 0xf8 / 255.0, green: 0xf8 / 255.0, blue: 0xf8 / 255.0, alpha: 1)
    })
    static let secondaryBg = Color(UIColor.secondarySystemBackground)
    static let inputIconBg = Color(UIColor.secondarySystemBackground)
    static let inputIconBorder = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.35, alpha: 1) : UIColor(white: 0, alpha: 0) })
    static let inputBg = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.12, alpha: 1) : .white })
    static let inputBorder = Color(UIColor.separator)
    static let primaryText = Color(UIColor.label)
    static let secondaryText = Color(UIColor.secondaryLabel)
    static let tertiaryText = Color(UIColor.tertiaryLabel)
    static let userBubble = Color(UIColor.tertiarySystemFill)
    static let toolBg = Color(UIColor.tertiarySystemGroupedBackground)
    static let toolBorder = Color(UIColor.separator).opacity(0.5)
    static let accent = Color(UIColor.label)
    static let sendButton = Color(UIColor.label)
    static let sendButtonDisabled = Color(UIColor.quaternaryLabel)
}

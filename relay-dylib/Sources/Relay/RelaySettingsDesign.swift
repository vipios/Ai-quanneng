//
//  RelaySettingsDesign.swift
//  RelayDylib — 设置页视觉参数（照 fork 的 SettingsDesign.swift 1:1 搬）
//
//  为什么复制一份而不是 import App 的：
//    dylib 是独立 module，编译期拿不到 App 内部的 `SettingsDesign` /
//    `SettingsRowContent`（它们是 internal Swift 类型，不在任何 @objc 桥上）。
//    所以把设计稿的数值原样抄一份到本地 —— 数值和 fork 完全一致，官方更新
//    App 也不会影响这套视觉。
//
//  数值来源：src/ios/Views/Settings/SettingsDesignTokens.swift（R42）
//    · 图标 29×29 圆角 7.5，符号 17pt
//    · 标题 17pt regular，副标题 13pt regular
//    · 行左右 padding 16 / 上下 11，最小高 52，图标到文字 gap 13
//    · 分组标题 13pt/600，左缩进 34，底色用设计稿固定色值
//

import SwiftUI

// MARK: - 设计 token（数值照搬 fork）

enum RelaySettingsDesign {
    static let cardInset: CGFloat = 16
    static let cardRadius: CGFloat = 14
    static let rowPaddingH: CGFloat = 16
    static let rowPaddingV: CGFloat = 11
    static let rowMinHeight: CGFloat = 52
    static let rowGap: CGFloat = 13
    static let iconSize: CGFloat = 29
    static let iconRadius: CGFloat = 7.5
    static let iconGlyph: CGFloat = 17
    static let separatorInset: CGFloat = 56
    static let sectionHeaderTop: CGFloat = 22
    static let sectionHeaderBottom: CGFloat = 8
    static let sectionHeaderLeading: CGFloat = 34

    static let titleFont = Font.system(size: 17, weight: .regular)
    static let subFont = Font.system(size: 13, weight: .regular)
    static let sectionHeaderFont = Font.system(size: 13, weight: .semibold)

    // 设计稿固定色（照搬 SixDesign 的十六进制值）
    static let blue   = Color(red: 0x00 / 255, green: 0x7A / 255, blue: 0xFF / 255)
    static let green  = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    static let red    = Color(red: 0xFF / 255, green: 0x3B / 255, blue: 0x30 / 255)
    static let orange = Color(red: 0xFF / 255, green: 0x95 / 255, blue: 0x00 / 255)
    static let indigo = Color(red: 0x58 / 255, green: 0x56 / 255, blue: 0xD6 / 255)
    static let teal   = Color(red: 0x30 / 255, green: 0xB0 / 255, blue: 0xC7 / 255)
    static let gray   = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)
}

// MARK: - 一行设置的外观（照搬 SettingsRowContent）

/// 圆角彩色图标块 + 17pt 标题 + 13pt 副标题，数值全部来自 RelaySettingsDesign。
struct RelaySettingsRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String?
    /// 某些 SF Symbol 天生偏小（server.rack 等），单独放大。
    var glyphScale: CGFloat = 1

    var body: some View {
        HStack(spacing: RelaySettingsDesign.rowGap) {
            Image(systemName: symbol)
                .font(.system(size: RelaySettingsDesign.iconGlyph * glyphScale,
                              weight: .medium))
                .foregroundStyle(.white)
                .frame(width: RelaySettingsDesign.iconSize,
                       height: RelaySettingsDesign.iconSize)
                .background(tint,
                            in: RoundedRectangle(cornerRadius: RelaySettingsDesign.iconRadius,
                                                 style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(RelaySettingsDesign.titleFont)
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(RelaySettingsDesign.subFont)
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RelaySettingsDesign.rowPaddingH)
        .padding(.vertical, RelaySettingsDesign.rowPaddingV)
        .frame(minHeight: RelaySettingsDesign.rowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

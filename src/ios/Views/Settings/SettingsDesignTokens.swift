//
//  SettingsDesignTokens.swift
//  全能AI - 设置页视觉参数（R42）
//
//  ============================================================
//  这个文件的唯一职责：把设计稿 `ui.html` 里设置页的那套数值，
//  一对一地搬成 Swift 常量。
//
//  为什么单独抽一个文件
//  ------------------------------------------------------------
//  原版设置页用的是 SwiftUI 默认的 `List` chrome：图标 21pt 圆形、
//  行高由系统决定、分组标题是系统的小写字距。设计稿是另一套完全
//  不同的度量 —— 图标 29×29 圆角 7.5、行最小高 52、标题 17pt、
//  副标题 13pt、卡片圆角 14、左右边距 16、分组标题 13pt/600 且
//  左缩进 34。
//
//  这些数值如果直接散在 SettingsSheet.swift 的几十个 modifier 里，
//  下次想调一个字号就要通读整个 700 行的文件，还会漏掉某几处。
//  集中在这里之后，「设计稿改了」= 只改这一个文件。
//
//  数值来源全部标注了 ui.html 的行号，方便对照：
//    · #stBody .grp-head   → 分组标题
//    · #stBody .card       → 卡片
//    · #stBody .row        → 行
//    · #stBody .ico        → 图标
//    · #stBody .row-title  → 主标题
//    · #stBody .row-sub    → 副标题
//    · #stBody .row-val    → 右侧值
//    · #stBody .arrow      → 箭头
//
//  刻意不做的事
//  ------------------------------------------------------------
//  · 不动功能代码。这一版只换皮：跳转、改名、开关、同步全部走原来的
//    实现。所以这里只有外观常量，没有任何行为。
//  · 不用 `Color(.systemGray...)` 之外的语义色去覆盖设计稿的固定色值。
//    设计稿是浅色底的 iOS 卡片，为了和截图一致，图标底色用设计稿里
//    那组固定色；文字颜色仍然用语义色（label/secondary），这样深色
//    模式下不会白底黑字看不清。
//

import SwiftUI

enum SettingsDesign {

    // MARK: - 布局

    /// 卡片左右留白。设计稿 `#stBody .card{ margin:0 16px }`。
    static let cardInset: CGFloat = 16

    /// 卡片圆角。`border-radius:14px`。
    static let cardRadius: CGFloat = 14

    /// 行左右内边距。`.row{ padding:11px 16px }` 里的水平 16。
    static let rowPaddingH: CGFloat = 16

    /// 行上下内边距。`.row{ padding:11px 16px }` 里的垂直 11。
    static let rowPaddingV: CGFloat = 11

    /// 行最小高度。`min-height:52px`。
    ///
    /// 为什么要有「最小」而不是写死高度：有副标题的行会自然更高，
    /// 写死 52 会把副标题压掉。设计稿也是 min-height。
    static let rowMinHeight: CGFloat = 52

    /// 图标与文字之间。`.row{ gap:13px }`。
    static let rowGap: CGFloat = 13

    /// 图标边长。`.ico{ width:29px; height:29px }`。
    static let iconSize: CGFloat = 29

    /// 图标圆角。`border-radius:7.5px`。
    ///
    /// 7.5 是设计稿的精确值，不是 8 —— 29pt 的方块上用 8 会显得偏方，
    /// 7.5 才是那点「圆但不圆成胶囊」的观感。
    static let iconRadius: CGFloat = 7.5

    /// 图标里符号的大小。`.ico svg{ width:17px; height:17px }`。
    ///
    /// 17 而不是图标本身 29：设计稿的图标是「17 的图形放在 29 的底色里」，
    /// 留出的 6pt 边才是它看起来透气的原因。
    static let iconGlyph: CGFloat = 17

    /// 分隔线左缩进。`.row.inset + .row::before{ left:56px }`。
    ///
    /// 56 = 16（行左padding）+ 29（图标）+ 13（gap）- 2（轻微压进图标
    /// 下方，让线看起来从文字开头起）。原版 List 的默认 inset 是 16，
    /// 会和图标根部交叉，看着很脏。
    static let separatorInset: CGFloat = 56

    /// 分组标题上下留白。`padding:22px 34px 8px`。
    static let sectionHeaderTop: CGFloat = 22
    static let sectionHeaderBottom: CGFloat = 8
    /// 分组标题左缩进。同上那行的 34。
    static let sectionHeaderLeading: CGFloat = 34

    /// 列表底部留白。`#stBody{ padding-bottom:24px }`。
    static let listBottomPadding: CGFloat = 24

    // MARK: - 字体

    /// 行主标题。`font-size:17px`，不加粗（设计稿没写 font-weight，
    /// 默认 400；比原版 List 的 body 略大一点）。
    static let titleFont = Font.system(size: 17, weight: .regular)

    /// 行副标题。`font-size:13px`。
    static let subFont = Font.system(size: 13, weight: .regular)

    /// 右侧值（版本号之类）。`font-size:17px`。
    static let valueFont = Font.system(size: 17, weight: .regular)

    /// 分组标题。`font-size:13px; font-weight:600`。
    ///
    /// 注意设计稿这里用的是 `--label`（黑），不是系统的灰色 —— 这是它
    /// 和原生 List header 观感差别最大的地方，也是「一眼像设计稿」的
    /// 关键。所以这里传的是 primary 语义色，不是 secondary。
    static let sectionHeaderFont = Font.system(size: 13, weight: .semibold)

    /// 箭头大小。`.arrow{ width:8px; height:14px }`。
    static let arrowSize = CGSize(width: 8, height: 14)

    // MARK: - 图标底色
    //
    // 设计稿里每个分组用固定的六个色轮转（`.t-red/.t-blue/...`）。
    // 原版用的是 SwiftUI 的 `.blue / .green / .indigo` 这类系统色，
    // 在浅色底上偏亮、饱和度也低一档。
    //
    // 这里用设计稿那组十六进制值，保持和截图一致。

    static let blue   = Color(red: 0x00/255, green: 0x7A/255, blue: 0xFF/255)
    static let green  = Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255)
    static let red    = Color(red: 0xFF/255, green: 0x3B/255, blue: 0x30/255)
    static let orange = Color(red: 0xFF/255, green: 0x95/255, blue: 0x00/255)
    static let indigo = Color(red: 0x58/255, green: 0x56/255, blue: 0xD6/255)
    static let teal   = Color(red: 0x30/255, green: 0xB0/255, blue: 0xC7/255)
    static let cyan   = Color(red: 0x32/255, green: 0xAD/255, blue: 0xE6/255)
    static let purple = Color(red: 0xAF/255, green: 0x52/255, blue: 0xDE/255)
    static let pink   = Color(red: 0xFF/255, green: 0x2D/255, blue: 0x55/255)
    static let gray   = Color(red: 0x8E/255, green: 0x8E/255, blue: 0x93/255)
    static let black  = Color(red: 0x1C/255, green: 0x1C/255, blue: 0x1E/255)
}

// MARK: - 行外观

/// 一行设置的外观包装。
///
/// 用法：把原来 `NavigationLink { dest } label: { Label { ... } icon: { ... } }`
/// 里的 `Label` 换成这个，`NavigationLink` 本身不动 —— 这样跳转行为、
/// 目标页面、长按改名全部保持原样，只换长相。
///
/// 为什么不直接改 `Label`：`Label` 在 List 里的排布由系统管，符号大小
/// 和文字缩进没法精确控制（`LabelStyle` 能改，但要为每个字号单独算
/// 间距）。自己排一个 HStack 反而更稳，也不会受 List 的 chrome 影响。
struct SettingsRowContent: View {

    let title: AnyView
    /// 图标符号名。传 nil 表示这行没有图标（设计稿里有几行是纯文字）。
    let symbol: String?
    /// 图标底色。nil 表示用系统默认（不画底色块）。
    let iconTint: Color?
    /// 图标符号的额外字号。有些 SF Symbol 天生偏小，需要单独放大
    /// （比如 server.rack 在 17pt 下几乎看不见）。
    let glyphScale: CGFloat
    /// 副标题。nil 表示这行只有一行字。
    let subtitle: String?

    init(title: AnyView,
         symbol: String? = nil,
         iconTint: Color? = nil,
         glyphScale: CGFloat = 1,
         subtitle: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.iconTint = iconTint
        self.glyphScale = glyphScale
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(spacing: SettingsDesign.rowGap) {
            if let symbol {
                icon(symbol)
            }

            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(SettingsDesign.titleFont)
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SettingsDesign.subFont)
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsDesign.rowPaddingH)
        .padding(.vertical, SettingsDesign.rowPaddingV)
        // 最小高度而不是固定高度：有副标题的行自然会长，写死会把字压掉。
        .frame(minHeight: SettingsDesign.rowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: SettingsDesign.iconGlyph * glyphScale,
                          weight: .medium))
            .foregroundStyle(.white)
            .frame(width: SettingsDesign.iconSize,
                   height: SettingsDesign.iconSize)
            .background(iconTint ?? Color(.systemGray),
                        in: RoundedRectangle(cornerRadius: SettingsDesign.iconRadius,
                                             style: .continuous))
    }
}

// MARK: - 二级页统一外壳

/// 二级页（技能 / 人格 / 说话模式 / 中转站后台 / 路由器后台 …）的
/// 统一外观。
///
/// 为什么需要这个：设置首页换皮只解决了「首页像设计稿」，点进任何
/// 二级页又回到系统 `Form` / `List` 的样子 —— 圆角、行高、图标底色
/// 全不一样，一进一出像两个 App。用户要的是「后面加的功能都和模板
/// UI 一样」，那就得有一个所有二级页共用的外壳。
///
/// 做什么：
///   · 统一底色（`systemGroupedBackground`）和导航标题样式；
///   · 把里面的 `Form` / `List` 的默认 chrome 压掉一点 —— 具体做法是
///     给内容套一层 `scrollContentBackground(.hidden)` + 自定义背景，
///     让系统不再画自己的分组白底和分隔线。
///
/// 刻意不做的事：
///   · 不改内部的行结构。这些页面各有各的行（开关、输入框、带按钮的），
///     逐个重排风险远大于收益，也容易把功能碰坏。这里只处理「外壳」。
///   · 不强行把所有 Form 换成自绘卡片。Form 自带的 section 折叠、键盘
///     避让、滚动吸顶都是系统给的好处，换掉要一项项补回来。
struct SettingsPageChrome: ViewModifier {

    func body(content: Content) -> some View {
        content
            // 让 Form / List 不再画自己的分组底色，透出统一背景。
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    /// 按设计稿的样式给一个二级设置页套外壳。
    ///
    /// 用法：在页面最外层 `.modifier(SettingsPageChrome())` 或 `.settingsPageChrome()`。
    func settingsPageChrome() -> some View {
        modifier(SettingsPageChrome())
    }
}

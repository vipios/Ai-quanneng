//
//  RelayPageChrome.swift
//  RelayDylib — 二级页外壳修饰符
//
//  搬自 App 的 src/ios/Views/Settings/SettingsDesignTokens.swift。
//  为什么必须复制一份：那是主 App 模块里的 extension，dylib 是独立模块，
//  链接期能靠 -undefined dynamic_lookup 找到符号，但**类型检查期**看不到
//  声明 —— 直接用 .settingsPageChrome() 会报 "no member"。
//
//  内容与上游保持一致，没有改动；哪天上游改了样式，这里要跟着对。
//

import SwiftUI

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
    func settingsPageChrome() -> some View {
        modifier(SettingsPageChrome())
    }
}

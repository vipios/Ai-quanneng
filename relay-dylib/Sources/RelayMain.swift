//
//  RelayMain.swift
//  RelayDylib — 注入进官方 Minis 的中转站/路由器入口
//
//  ============================================================
//  为什么入口是「悬浮小圆点」而不是设置页里插一行
//
//  设置页是 SwiftUI 的 List，没有可 hook 的 UITableViewDataSource，
//  要插一行只能去猜内部视图层级、拿反射改结构 —— 官方一改版就碎，
//  而那正好是「dylib 注入」这个方案唯一要避免的事。
//
//  悬浮点只依赖两样从来不变的东西：UIWindow 和 UIViewController.present。
//  官方怎么重写设置页、怎么换导航，它都能打开。
//  ============================================================
//
//  加载时序：constructor 跑在 UIApplicationMain 之前，那时没有窗口。
//  所以这里统一「延后 + 有限次重试」，不是靠一次 sleep 蒙过去。
//

import Foundation
import UIKit
import SwiftUI

private let relayLog = { (msg: String) in NSLog("[RelayDylib] %@", msg) }

// MARK: - 入口

/// Swift 侧导出的 C 符号，由 RelayEntry.m 的 constructor 调用。
@_cdecl("RelayDylibMain")
public func RelayDylibMain() {
    relayLog("dylib 已加载")
    // 主队列 + 延后：给 UIApplicationMain 把窗口建起来的时间。
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        RelayBallInstaller.shared.begin()
    }
}

// MARK: - 悬浮球

final class RelayBallInstaller: NSObject {

    static let shared = RelayBallInstaller()

    private var ball: UIButton?
    private var sheet: UIViewController?
    private var retries = 0
    /// 1.0s 起步、每次 +0.5s，最多 24 次 —— 覆盖到冷启动最慢的机型。
    private let maxRetries = 24
    /// 拖动判定：手指移动超过这个距离就不算「点」。
    private let dragThreshold: CGFloat = 6

    private var dragStart: CGPoint = .zero
    private var dragged = false

    func begin() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        install()
    }

    /// 回前台时窗口可能被重建（比如从分享扩展回来），球会跟着旧窗口一起没了。
    @objc private func didBecomeActive() {
        if ball?.window == nil {
            ball?.removeFromSuperview()
            ball = nil
            retries = 0
            install()
        }
    }

    private func install() {
        guard ball == nil else { return }

        guard let window = Self.keyWindow() else {
            guard retries < maxRetries else {
                relayLog("找不到 key window，放弃挂载（已重试 \(maxRetries) 次）")
                return
            }
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.install()
            }
            return
        }

        retries = 0
        let size: CGFloat = 52
        let inset: CGFloat = 10
        let button = UIButton(type: .custom)
        button.frame = CGRect(
            x: window.bounds.maxX - size - inset,
            y: window.bounds.height * 0.42,
            width: size,
            height: size
        )
        button.layer.cornerRadius = size / 2
        button.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.14)
                : UIColor.black.withAlphaComponent(0.06)
        }
        button.layer.borderWidth = 1 / UIScreen.main.scale
        button.layer.borderColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.22)
                : UIColor.black.withAlphaComponent(0.14)
        }.cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.18
        button.layer.shadowRadius = 6
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.tintColor = .label
        button.setImage(
            UIImage(
                systemName: "antenna.radiowaves.left.and.right",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            ),
            for: .normal
        )
        button.accessibilityLabel = "中转站"
        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        button.addGestureRecognizer(pan)

        window.addSubview(button)
        ball = button
        relayLog("悬浮球已挂载：\(window.bounds.size)")
    }

    // MARK: 拖动

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let ball, let window = ball.window else { return }
        let translation = gesture.translation(in: window)

        switch gesture.state {
        case .began:
            dragged = false
            dragStart = ball.center
        case .changed:
            if abs(translation.x) > dragThreshold || abs(translation.y) > dragThreshold {
                dragged = true
            }
            ball.center = CGPoint(x: dragStart.x + translation.x, y: dragStart.y + translation.y)
        case .ended, .cancelled:
            guard dragged else { return }
            // 贴最近的一侧，别让球停在屏幕正中挡内容
            let inset: CGFloat = 10
            let half = ball.bounds.width / 2
            let targetX: CGFloat = ball.center.x > window.bounds.midX
                ? window.bounds.maxX - half - inset
                : window.bounds.minX + half + inset
            let minY = window.bounds.minY + window.safeAreaInsets.top + half
            let maxY = window.bounds.maxY - window.safeAreaInsets.bottom - half
            let targetY = min(max(ball.center.y, minY), maxY)
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
                ball.center = CGPoint(x: targetX, y: targetY)
            }
        default:
            break
        }
    }

    // MARK: 打开面板

    @objc private func handleTap() {
        guard !dragged else { dragged = false; return }
        guard sheet == nil else { return }

        guard let presenter = Self.topViewController() else {
            relayLog("没有可用来 present 的视图控制器")
            return
        }
        // 已经有别的模态在上面时不要硬叠，iOS 会直接不显示
        guard presenter.presentedViewController == nil else {
            relayLog("当前已有模态页面，跳过")
            return
        }

        // 用 fullScreen：中转站后台是整页 WKWebView，pageSheet 的卡片高度
        // 会把后台界面压成一条缝。关闭按钮在 SwiftUI 侧（toolbar 里）。
        let host = UIHostingController(rootView: RelayHomeView())
        host.modalPresentationStyle = .fullScreen
        presenter.present(host, animated: true)
        sheet = host
    }

    // MARK: 找窗口 / 找顶层控制器

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        }
        return scenes.first?.windows.first
    }

    private static func topViewController() -> UIViewController? {
        guard let root = keyWindow()?.rootViewController else { return nil }
        var top = root
        while true {
            if let presented = top.presentedViewController {
                top = presented
                continue
            }
            if let nav = top as? UINavigationController, let visible = nav.visibleViewController {
                if visible === top { break }
                top = visible
                continue
            }
            if let tab = top as? UITabBarController, let selected = tab.selectedViewController {
                if selected === top { break }
                top = selected
                continue
            }
            break
        }
        return top
    }
}

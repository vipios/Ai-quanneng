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

/// 模块内共用（RelayProxy 等文件也要打日志）。顶层 private 只在单文件可见。
let relayLog: (String) -> Void = { (msg: String) in NSLog("[RelayDylib] %@", msg) }

// MARK: - 入口

/// Swift 侧导出的 C 符号，由 RelayEntry.m 的 constructor 调用。
@_cdecl("RelayDylibMain")
public func RelayDylibMain() {
    relayLog("dylib 已加载")
    // 本地代理立刻起：聊天请求要走它实现无感换线。
    // 不依赖窗口，也不依赖用户点球 —— 必须在 App 发起第一个请求前就监听。
    RelayProxy.shared.start()
    // 主队列 + 延后：给 UIApplicationMain 把窗口建起来的时间。
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        RelayBallInstaller.shared.begin()
        // 线路判定要**常驻**，不能等用户点开面板才开始算：
        //   · 启动 NWPathMonitor —— 用户在系统里把 WiFi 换成蜂窝，
        //     这边立刻收到回调并重判（否则界面上永远是打开时的那个结论）
        //   · 主动触发一次本地网络授权弹窗
        //   · 回前台重判一次
        // dylib 里没人替我们调它（fork 版是 MinisApp 调的），所以在这里调。
        // RelayStore 是 @MainActor，这里只是主队列，不是 actor —— 用 Task 进。
        Task { @MainActor in RelayStore.shared.bootstrap() }
        relayLog("线路判定已启动（常驻监听网络变化）")
    }
}

// MARK: - 独立浮层窗口
//
// 球挂在 App 的 keyWindow 上时，App 弹任何模态页、系统弹窗、键盘都会把它盖住，
// 而且 handleTap 里 `presentedViewController != nil` 会直接跳过 —— 表现就是
// 「某些界面看不到球 / 点了没反应」（用户 2026-11-18 要求任何界面都能操作）。
//
// 解法：自己开一个高层级透明窗口，球和面板都放这层：
//   · windowLevel 高于普通窗口和键盘 → 任何界面都盖不住
//   · 不做 keyWindow → 不影响 App 自己的窗口判定
//   · 根视图只让球吃触摸，其余区域穿透 → App 照样能正常点、能打字

/// RelayPassThroughView 定义在 Relay/RelayDrawer.swift（球 + 抽屉 + 遮罩三块吃触摸）。

/// 浮层窗口的根控制器。抽屉挂在这个根视图上，不依赖 App 当前的顶层控制器。
private final class RelayOverlayViewController: UIViewController {
    override func loadView() {
        let v = RelayPassThroughView()
        v.backgroundColor = .clear
        view = v
    }
}

// MARK: - 悬浮球

final class RelayBallInstaller: NSObject {

    static let shared = RelayBallInstaller()

    private var ball: UIButton?
    /// 独立浮层窗口：球和面板都挂这里，App 任何界面、任何模态都盖不住。
    private var overlayWindow: UIWindow?
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

    /// 回前台时如果浮层窗口没了就重建。独立窗口不依赖 App 的 keyWindow，
    /// 比原来挂 App 窗口上稳得多 —— App 换根控制器、重建窗口都不影响它。
    @objc private func didBecomeActive() {
        if ball?.window == nil || overlayWindow == nil {
            RelayDrawer.shared.detach()
            ball?.removeFromSuperview()
            ball = nil
            overlayWindow?.isHidden = true
            overlayWindow = nil
            sheet = nil
            retries = 0
            install()
        }
    }

    private func install() {
        guard ball == nil else { return }

        guard let scene = Self.foregroundScene() else {
            guard retries < maxRetries else {
                relayLog("找不到前台 window scene，放弃挂载（已重试 \(maxRetries) 次）")
                return
            }
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.install()
            }
            return
        }

        retries = 0

        // 自己的浮层窗口：level 高于普通窗口和键盘，但不当 keyWindow。
        // 用 .alert + 1：系统键盘是 .alert，比它高一层才能盖住键盘。
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level.alert + 1
        // 新建窗口的 bounds 要到下一个布局周期才有效，这里显式给 frame，
        // 否则下面算球的初始坐标时会拿到 .zero，把球放到屏幕外。
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = RelayOverlayViewController()
        window.backgroundColor = .clear
        window.isHidden = false
        overlayWindow = window

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

        guard let root = window.rootViewController as? RelayOverlayViewController,
              let passView = root.view as? RelayPassThroughView else {
            relayLog("浮层根视图类型不对，挂载失败")
            window.isHidden = true
            overlayWindow = nil
            return
        }

        // 顶部导航条（照 fork 聊天页 1:1）：先挂它，球和抽屉盖在它上面。
        // 整条只有左上角圆气泡吃触摸，其余穿给 App —— 见 RelayChatNavBar。
        let navBar = RelayChatNavBarHost()
        root.addChild(navBar)
        navBar.view.frame = CGRect(x: 0, y: 0, width: window.bounds.width,
                                   height: RelayChatNavBarMetrics.totalHeight)
        passView.addSubview(navBar.view)
        navBar.didMove(toParent: root)
        passView.navBar = navBar.view

        passView.ball = button
        passView.addSubview(button)
        ball = button
        // 左滑抽屉挂到同一个浮层根视图上（任何界面都能拉出）。
        RelayDrawer.shared.attach(to: window, passView: passView)
        relayLog("悬浮球 + 导航条 + 左滑抽屉已挂载到独立浮层：\(window.bounds.size)")
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

        // 左滑抽屉开着时，点球就是收起它（两者共用一张首页，不叠加）。
        if RelayDrawer.shared.isOpen {
            RelayDrawer.shared.close()
            return
        }

        // 半屏圆角抽屉：从底部滑出、顶部圆角，都是 pageSheet 自带的。
        // medium detent = 半屏；只给这一档，保持抽屉形态（用户 2026-11-18 要求）。
        // 左滑抽屉是另一条入口（用户 2026-11-18 追加）：从屏幕左边缘右滑拉出，
        // 走 RelayDrawer，挂在同一个浮层窗口上。两条入口互不干扰。
        guard let presenter = overlayWindow?.rootViewController else {
            relayLog("浮层窗口不在，无法弹面板")
            return
        }
        // 浮层上如果还留着上一张没关干净的面板，先收掉再弹新的
        if let stuck = presenter.presentedViewController {
            stuck.dismiss(animated: false)
            sheet = nil
        }

        let host = UIHostingController(rootView: RelayHomeView())
        host.modalPresentationStyle = .pageSheet
        if let sheetCtrl = host.sheetPresentationController {
            sheetCtrl.detents = [.medium()]
        }
        presenter.present(host, animated: true)
        sheet = host
    }

    // MARK: 关闭 / 弹提示（给 SwiftUI 侧用）

    /// 关掉首页。
    ///
    /// 不用 SwiftUI 的 `@Environment(\.dismiss)`：它只把视图上的东西关掉，
    /// 拿不回 `sheet` 这个引用 —— 页面关了、`sheet` 还非 nil，悬浮球就再也
    /// 点不开了。这里统一由持有者关，关的同时把引用清掉。
    func closeHome() {
        // 左滑抽屉里的关闭按钮也走这里 —— 两条入口都收掉。
        if RelayDrawer.shared.isOpen { RelayDrawer.shared.close() }
        guard let host = sheet else { return }
        // 先清引用再 dismiss：dismiss 的回调里再取 self.sheet 时已经是 nil。
        sheet = nil
        host.dismiss(animated: true)
    }

    /// 在当前最上层弹一个提示。
    ///
    /// 加一条服务商的结果（成功 / 被拒 / 没权限）只有这里能告诉用户：
    /// 那时输入页已经关了，没有页面可以承载结果。
    ///
    /// 带重试：App 的确认弹窗收回去有动画，收完之前 `presentedViewController`
    /// 还非 nil，直接 present 会失败（UIKit 只打一行 warning）。所以每 0.4s
    /// 试一次，最多 5 次；真的叠着别的东西就放弃，总比崩了好。
    func presentAlert(title: String, message: String, attempt: Int = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let presenter = self.overlayWindow?.rootViewController else { return }

            guard presenter.presentedViewController == nil else {
                guard attempt < 5 else {
                    relayLog("结果提示弹不出来：\(title) — \(message)")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.presentAlert(title: title, message: message, attempt: attempt + 1)
                }
                return
            }

            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            presenter.present(alert, animated: true)
        }
    }

    // MARK: 找前台 scene

    /// 独立浮层只需要一个前台 scene，不需要 App 的 keyWindow / 顶层控制器。
    private static func foregroundScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first
    }
}

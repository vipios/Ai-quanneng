//
//  RelayDrawer.swift
//  RelayDylib — 左滑抽屉
//
//  交互照搬 fork ipa 里的 EdgeDrawer.swift（用户 2026-11-18 确认「我们 ipa 里设置过的」）：
//    · 从屏幕左边缘右滑拉出抽屉，右侧留一条（peekStrip）
//    · 抽屉宽 = 屏宽 − 54，上限 348
//    · 跟手拖动，松手按速度 + 位移吸附，过中线轻震一下
//    · 点右侧遮罩 / 往左滑 收起
//
//  但容器不同：ipa 里抽屉是 App 的 DrawerContainer（要改 ContentView 源码）。
//  dylib 进的是官方包，改不了它的视图树，所以这里把抽屉挂在**自己的浮层窗口**上
//  —— 任何界面（含系统弹窗、键盘、App 的模态页）都能左滑拉出。
//

import UIKit
import SwiftUI

/// 左滑抽屉控制器。挂在 RelayBallInstaller 的浮层窗口上。
final class RelayDrawer: NSObject, UIGestureRecognizerDelegate {

    static let shared = RelayDrawer()

    /// 抽屉展开后，右侧留出的那条宽度（pt）。与 ipa 的 DrawerState.peekStrip 一致。
    private static let peekStrip: CGFloat = 54
    /// 抽屉宽度上限。与 ipa 的 DrawerState.widthMax 一致。
    private static let widthMax: CGFloat = 348

    /// 抽屉是否展开（给悬浮球点击时判断「点一下是开还是关」）。
    private(set) var isOpen = false

    private weak var window: UIWindow?
    private weak var passView: UIView?
    private var drawerHost: UIHostingController<RelayHomeView>?
    private var dimView: UIView?
    private var edgePan: UIScreenEdgePanGestureRecognizer?

    private var startX: CGFloat = 0

    private func width(for window: UIWindow) -> CGFloat {
        let w = window.bounds.width
        return max(min(w - Self.peekStrip, Self.widthMax), w * 0.62)
    }

    // MARK: - 挂载

    /// 把左边缘手势挂到浮层根视图上。浮层重建时要重新挂。
    func attach(to window: UIWindow, passView: UIView) {
        detach()
        self.window = window
        self.passView = passView

        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        edge.edges = .left
        edge.delegate = self
        // 识别成功也不取消底层按钮的触摸。
        edge.cancelsTouchesInView = false
        passView.addGestureRecognizer(edge)
        edgePan = edge
    }

    /// 浮层重建 / 拆除时把手势和视图摘干净。
    func detach() {
        if let edgePan { edgePan.view?.removeGestureRecognizer(edgePan) }
        edgePan = nil
        drawerHost?.view.removeFromSuperview()
        drawerHost = nil
        dimView?.removeFromSuperview()
        dimView = nil
        passView?.drawer = nil
        passView?.dim = nil
        isOpen = false
        window = nil
        passView = nil
    }

    // MARK: - 开 / 关

    /// 展开（悬浮球点击走这里）。
    func open() {
        guard let window else { return }
        ensureViews()
        isOpen = true
        dimView?.isHidden = false
        UIView.animate(withDuration: 0.32,
                       delay: 0,
                       usingSpringWithDamping: 0.86,
                       initialSpringVelocity: 0,
                       options: [.curveEaseOut]) {
            self.drawerHost?.view.transform = .identity
            self.dimView?.alpha = 0.38
        }
    }

    /// 收起（抽屉里的关闭按钮、点遮罩、左滑都走这里）。
    func close() {
        guard let window else { return }
        let w = width(for: window)
        isOpen = false
        UIView.animate(withDuration: 0.28,
                       delay: 0,
                       usingSpringWithDamping: 0.92,
                       initialSpringVelocity: 0,
                       options: [.curveEaseIn]) {
            self.drawerHost?.view.transform = CGAffineTransform(translationX: -w, y: 0)
            self.dimView?.alpha = 0
        } completion: { [weak self] _ in
            guard let self, !self.isOpen else { return }
            self.dimView?.isHidden = true
        }
    }

    /// 首次使用时把抽屉和遮罩建出来。
    /// 顺序：先遮罩、后抽屉 —— 抽屉在上，投影才能盖在遮罩上。
    private func ensureViews() {
        guard let window, let passView else { return }

        if dimView == nil {
            let dim = UIView(frame: passView.bounds)
            dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dim.backgroundColor = .black
            dim.alpha = 0
            dim.isHidden = true

            let tap = UITapGestureRecognizer(target: self, action: #selector(tapDim))
            tap.cancelsTouchesInView = true
            dim.addGestureRecognizer(tap)

            let swipe = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            swipe.delegate = self
            swipe.cancelsTouchesInView = false
            dim.addGestureRecognizer(swipe)

            passView.addSubview(dim)
            dimView = dim
            passView.dim = dim
        }

        if drawerHost == nil {
            let host = UIHostingController(rootView: RelayHomeView())
            let w = width(for: window)
            host.view.frame = CGRect(x: 0, y: 0, width: w, height: window.bounds.height)
            host.view.transform = CGAffineTransform(translationX: -w, y: 0)
            host.view.backgroundColor = UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0x1C/255, green: 0x1C/255, blue: 0x1E/255, alpha: 1)
                    : UIColor(red: 0xF8/255, green: 0xF8/255, blue: 0xF8/255, alpha: 1)
            }
            host.view.layer.shadowColor = UIColor.black.cgColor
            host.view.layer.shadowOpacity = 0.25
            host.view.layer.shadowRadius = 12
            host.view.layer.shadowOffset = CGSize(width: 4, height: 0)
            passView.addSubview(host.view)
            drawerHost = host
            passView.drawer = host.view
        }
    }

    // MARK: - 手势

    @objc private func tapDim() {
        close()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let window else { return }
        let w = width(for: window)
        let tx = g.translation(in: g.view).x

        switch g.state {
        case .began:
            ensureViews()
            startX = isOpen ? 0 : -w
            dimView?.isHidden = false

        case .changed:
            // 跟手：夹在 −w（收起）… 0（展开）之间，手势期间不加动画。
            var x = startX + tx
            x = max(-w, min(0, x))
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                self.drawerHost?.view.transform = CGAffineTransform(translationX: x, y: 0)
                self.dimView?.alpha = ((x + w) / w) * 0.38
            }

        case .ended, .cancelled, .failed:
            let velocity = g.velocity(in: g.view).x
            let currentX = drawerHost?.view.transform.tx ?? -w
            // 先看速度（快速轻扫），再看位移过没过半。
            let shouldOpen: Bool
            if velocity > 400 { shouldOpen = true }
            else if velocity < -400 { shouldOpen = false }
            else { shouldOpen = currentX > -w * 0.5 }
            shouldOpen ? open() : close()

        default:
            break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    /// edgePan 只认「从左边缘往右」的拉出；遮罩上的左滑收起手势直接放行。
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // 遮罩上的左滑收起（swipe）和点击（tap）：点在遮罩上本来就是要关，
        // 不需要方向判断。tap 没设 delegate 不会走这里；这里主要放行 swipe。
        guard g === edgePan else { return true }
        guard let window else { return false }
        guard !isOpen else { return false }

        let velocity = g.velocity(in: window)
        let startY = g.location(in: window).y - g.translation(in: window).y
        // 顶部状态栏 + 导航栏那一段让给系统（返回键 / 通知中心）。
        guard startY >= window.safeAreaInsets.top + 44 else { return false }
        // 水平速度要明显大于垂直，斜划时让列表赢。
        guard abs(velocity.x) > abs(velocity.y) * 1.3 else { return false }
        return velocity.x > 0
    }
}

// MARK: - 浮层根视图（让抽屉和遮罩也能吃触摸）

/// 全屏透明；只有球、抽屉、遮罩三块接收触摸，其余穿给 App。
/// 左边缘 44pt 留给自己接侧滑手势（和系统返回手势同一条边，接管它）。
final class RelayPassThroughView: UIView {
    weak var ball: UIView?
    weak var drawer: UIView?
    weak var dim: UIView?
    /// 顶部导航条容器。整条只有左上角圆气泡吃触摸（其余 allowsHitTesting(false)），
    /// 所以命中它 = 命中那颗气泡；标题区/过渡带照旧穿给 App。
    weak var navBar: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let drawer, !drawer.isHidden, drawer.alpha > 0.01 {
            let p = drawer.convert(point, from: self)
            if drawer.point(inside: p, with: event) { return drawer }
        }
        if let dim, !dim.isHidden, dim.alpha > 0.01 {
            let p = dim.convert(point, from: self)
            if dim.point(inside: p, with: event) { return dim }
        }
        // 导航条：只把「左上角圆气泡」那一小块交给它。整条 navBar view 是
        // 123pt 全宽，若整条命中会挡住 App 原生返回键和 ⋯；SwiftUI 内部的
        // allowsHitTesting(false) 在 point(inside:) 这层看不出来，必须按坐标判。
        if let navBar, !navBar.isHidden, navBar.alpha > 0.01,
           RelayChatNavBarMetrics.leftBubbleFrame.contains(point) {
            let p = navBar.convert(point, from: self)
            if navBar.point(inside: p, with: event) { return navBar }
        }
        if let ball, !ball.isHidden, ball.alpha > 0.01 {
            let p = ball.convert(point, from: self)
            if ball.point(inside: p, with: event) { return ball }
        }
        if point.x <= 44 { return self }
        return nil
    }
}

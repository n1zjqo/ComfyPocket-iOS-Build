import SwiftUI
import UIKit

struct CanvasSwipeDecision {
    static func canBegin(velocity: CGPoint, cleared: Bool) -> Bool {
        abs(velocity.x) > 12 && abs(velocity.x) > abs(velocity.y) * 1.35 && (cleared ? velocity.x < 0 : velocity.x > 0)
    }

    static func progress(translation: CGFloat, width: CGFloat, cleared: Bool) -> CGFloat {
        min(1, max(0, (cleared ? 1 : 0) + translation / max(1, width)))
    }

    static func destination(progress: CGFloat, velocity: CGFloat, width: CGFloat, cleared: Bool, cancelled: Bool) -> Bool {
        if cancelled { return cleared }
        let projected = min(1, max(0, progress + velocity / max(1, width) * 0.16))
        return cleared ? projected > 0.65 : projected >= 0.35
    }
}

final class CanvasClearState: ObservableObject {
    @Published private(set) var progress: CGFloat = 0
    @Published private(set) var isCleared = false
    @Published private(set) var isDragging = false
    @Published private(set) var viewportWidth: CGFloat = 0

    func updateViewport(width: CGFloat) {
        if width > 0 && abs(width - viewportWidth) > 0.5 { viewportWidth = width }
    }

    func begin() { isDragging = true }

    func drag(translation: CGFloat, width: CGFloat) {
        progress = CanvasSwipeDecision.progress(translation: translation, width: width, cleared: isCleared)
    }

    func finish(velocity: CGFloat, width: CGFloat, cancelled: Bool) {
        let cleared = CanvasSwipeDecision.destination(progress: progress, velocity: velocity, width: width, cleared: isCleared, cancelled: cancelled)
        isDragging = false
        setCleared(cleared)
    }

    func setCleared(_ cleared: Bool) {
        isDragging = false
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.24)) {
            isCleared = cleared
            progress = cleared ? 1 : 0
        }
    }
}

struct CanvasSwipeBridge: UIViewRepresentable {
    @ObservedObject var canvas: CanvasClearState
    let enabled: Bool

    func makeUIView(context: Context) -> CanvasSwipeView { CanvasSwipeView(canvas: canvas) }

    func updateUIView(_ view: CanvasSwipeView, context: Context) {
        view.canvas = canvas
        view.pan.isEnabled = enabled
        view.updateTabBar(animated: context.transaction.animation != nil && !canvas.isDragging)
    }

    static func dismantleUIView(_ view: CanvasSwipeView, coordinator: ()) { view.detach() }
}

final class CanvasSwipeView: UIView, UIGestureRecognizerDelegate {
    var canvas: CanvasClearState
    private(set) lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    private weak var tabBar: UITabBar?
    private var installed = false

    init(canvas: CanvasClearState) {
        self.canvas = canvas
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detach() }
        else { install() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        install()
        if let width = window?.bounds.width, abs(width - canvas.viewportWidth) > 0.5 {
            DispatchQueue.main.async { [weak self] in self?.canvas.updateViewport(width: width) }
        }
        if !canvas.isDragging { updateTabBar(animated: false) }
    }

    private func install() {
        guard window != nil else { return }
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController {
                if !installed {
                    controller.view.addGestureRecognizer(pan)
                    installed = true
                }
                if let bar = window.flatMap({ findTabBar(in: $0) }) ?? findTabBar(in: controller), tabBar !== bar {
                    tabBar = bar
                    updateTabBar(animated: false)
                }
                return
            }
            responder = current.next
        }
    }

    private func findTabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for child in view.subviews {
            if let bar = findTabBar(in: child) { return bar }
        }
        return nil
    }

    private func findTabBar(in controller: UIViewController) -> UITabBar? {
        if let bar = controller.tabBarController?.tabBar { return bar }
        if let tabs = controller as? UITabBarController { return tabs.tabBar }
        for child in controller.children {
            if let bar = findTabBar(in: child) { return bar }
        }
        return nil
    }

    func detach() {
        pan.view?.removeGestureRecognizer(pan)
        installed = false
        tabBar?.layer.removeAllAnimations()
        tabBar?.transform = .identity
        tabBar?.alpha = 1
        tabBar?.isUserInteractionEnabled = true
        tabBar?.accessibilityElementsHidden = false
        tabBar = nil
    }

    func updateTabBar(animated: Bool) {
        guard let tabBar else { return }
        let transform = CGAffineTransform(translationX: (window?.bounds.width ?? bounds.width) * canvas.progress, y: 0)
        tabBar.alpha = canvas.isCleared && !canvas.isDragging ? 0 : 1
        tabBar.isUserInteractionEnabled = !canvas.isCleared
        tabBar.accessibilityElementsHidden = canvas.isCleared
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]) { tabBar.transform = transform }
        } else { tabBar.transform = transform }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view = pan.view else { return false }
        let point = pan.location(in: self)
        return bounds.contains(point) && CanvasSwipeDecision.canBegin(velocity: pan.velocity(in: view), cleared: canvas.isCleared)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var touched = touch.view
        while let view = touched {
            if view is UITextView || view is UITextField || view is UISlider { return false }
            touched = view.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer.view is UIScrollView
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let width = window?.bounds.width ?? bounds.width
        switch gesture.state {
        case .began:
            canvas.begin()
            window?.endEditing(true)
            canvas.drag(translation: gesture.translation(in: gesture.view).x, width: width)
        case .changed:
            canvas.drag(translation: gesture.translation(in: gesture.view).x, width: width)
        case .ended, .cancelled, .failed:
            canvas.finish(velocity: gesture.velocity(in: gesture.view).x, width: width, cancelled: gesture.state != .ended)
        default: break
        }
    }
}


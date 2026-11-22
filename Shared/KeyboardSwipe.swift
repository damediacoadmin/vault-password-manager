#if os(iOS)
import UIKit

/// Swipe down anywhere to put the keyboard away. Attached once to the whole window, so it works on
/// every screen, inside sheets, and in the AutoFill extension, even where nothing scrolls.
final class KeyboardSwipe: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardSwipe()

    func install(on view: UIView) {
        if view.gestureRecognizers?.contains(where: { $0.name == "vault.keyboardSwipe" }) == true { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        pan.name = "vault.keyboardSwipe"
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    @objc private func handle(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed || g.state == .ended, let v = g.view else { return }
        let t = g.translation(in: v)
        if t.y > 30 && abs(t.x) < t.y { v.endEditing(true) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif

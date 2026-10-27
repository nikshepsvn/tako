import AppKit
import SwiftUI

/// Tako's transparent mark for Sumi's button. It gently breathes while Sumi works
/// and grows slightly when Sumi needs you. Idle windows never animate the mark,
/// and Reduce Motion holds it still.
struct KuronamiMark: NSViewRepresentable {
    enum Mood: Equatable { case resting, working, needsYou }

    var mood: Mood

    /// Sumi's look: blocked on you always shows; an unseen reply only while its panel is closed.
    static func sumiMood(_ state: AgentState, unread: Bool, isOpen: Bool) -> Mood {
        switch state {
        case .working, .starting: return .working
        case .needsInput: return .needsYou
        default: return unread && !isOpen ? .needsYou : .resting
        }
    }

    func makeNSView(context: Context) -> MarkView { MarkView() }
    func updateNSView(_ view: MarkView, context: Context) { view.mood = mood }

    final class MarkView: NSView {
        private let tako = CALayer()
        private var laidOutBox = CGRect.zero

        var mood: Mood = .resting {
            didSet { if mood != oldValue { animate(from: oldValue) } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            if let url = Bundle.main.url(forResource: "tako", withExtension: "png", subdirectory: "Mark"),
               let image = NSImage(contentsOf: url) {
                tako.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            tako.contentsGravity = .resizeAspect
            layer?.addSublayer(tako)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionPreferenceChanged),
                                                              name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                              object: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            let side = min(bounds.width, bounds.height)
            let box = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            guard box != laidOutBox else { return }
            laidOutBox = box
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // CALayer.frame is undefined under a nonidentity transform.
            tako.transform = CATransform3DIdentity
            tako.frame = box
            CATransaction.commit()
            animate(from: nil)
        }

        @objc private func motionPreferenceChanged() { animate(from: nil) }

        private func animate(from previous: Mood?) {
            tako.removeAllAnimations()
            guard tako.bounds.height > 0 else { return }
            let scale: CGFloat = mood == .needsYou ? 1.08 : 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tako.transform = CATransform3DMakeScale(scale, scale, 1)
            CATransaction.commit()

            guard !Motion.reduced else { return }
            if let previous, (previous == .needsYou) != (mood == .needsYou) {
                let settle = CABasicAnimation(keyPath: "transform.scale")
                settle.fromValue = previous == .needsYou ? 1.08 : 1
                settle.toValue = scale
                settle.duration = 0.35
                settle.timingFunction = Motion.curve
                tako.add(settle, forKey: "settle")
            }
            guard mood == .working else { return }
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1
            breathe.toValue = 0.92
            breathe.duration = 0.8
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            tako.add(breathe, forKey: "breathe")
        }
    }
}

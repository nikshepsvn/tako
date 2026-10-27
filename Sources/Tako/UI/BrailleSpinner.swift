import AppKit
import SwiftUI

/// A small braille spinner; still (one glyph) with Reduce Motion.
///
/// The frames are a Core Animation keyframe animation on one layer's contents, so the render
/// server steps them. A SwiftUI `TimelineView` ticking at 10 Hz instead re-ran the sidebar's
/// layout ten times a second on the main thread for as long as any agent had a helper running.
struct BrailleSpinner: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }

    func updateNSView(_ view: SpinnerView, context: Context) { view.reduceMotion = reduceMotion }

    final class SpinnerView: NSView {
        static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        /// One full turn: ten frames at 10 Hz, as the TimelineView it replaces stepped them.
        static let period: CFTimeInterval = 1
        static let animationKey = "frames"
        private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        private static let color = NSColor(srgbRed: 0.494, green: 0.612, blue: 0.788, alpha: 1)

        private let glyph = CALayer()

        var reduceMotion = false {
            didSet { if reduceMotion != oldValue { restart() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            glyph.contentsGravity = .center
            layer?.addSublayer(glyph)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Every braille glyph is the same width in a monospaced font.
        override var intrinsicContentSize: NSSize {
            let size = (Self.frames[0] as NSString).size(withAttributes: [.font: Self.font])
            return NSSize(width: ceil(size.width), height: ceil(size.height))
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyph.frame = bounds
            CATransaction.commit()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            restart()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restart()
        }

        /// The frames for the current screen's scale, then the animation over them.
        private func restart() {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let images = Self.frames.compactMap { Self.render($0, scale: scale) }
            guard images.count == Self.frames.count else { return }
            glyph.removeAnimation(forKey: Self.animationKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyph.contentsScale = scale
            glyph.contents = images[0]
            CATransaction.commit()
            guard !reduceMotion else { return }
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = images
            animation.calculationMode = .discrete
            animation.duration = Self.period
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            glyph.add(animation, forKey: Self.animationKey)
        }

        private static func render(_ text: String, scale: CGFloat) -> CGImage? {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attributes)
            let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: .zero, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage()
        }
    }
}

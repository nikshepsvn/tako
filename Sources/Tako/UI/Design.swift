import AppKit
import GhosttyKit
import SwiftUI

// The design system. Every size, space, radius, color and motion in the interface comes from
// here; `scripts/lint-design.sh` fails the build check on raw values anywhere else.
//
// Principles:
// - Six text styles. Hierarchy comes from weight and color before size.
// - A 4-point grid. Three corner radii: controls, rows, panes.
// - Sumi ink and bone, like the icon's woodblock print. Color only ever means something, and
//   comes from traditional pigments: vermilion for the primary action, indigo for work in
//   progress, gold for "needs you", matcha for running, crimson for failure.
// - One motion curve, and none at all with Reduce Motion.

// MARK: - Type

enum Typeface {
    /// Empty states and sheet titles.
    static let title = Font.system(size: 17, weight: .semibold)
    /// Names: a session's label, a section's subject.
    static let headline = Font.system(size: 13, weight: .semibold)
    /// Running text and controls.
    static let body = Font.system(size: 13)
    /// Secondary lines under a headline.
    static let callout = Font.system(size: 12)
    /// Metadata, section headers, help text.
    static let caption = Font.system(size: 11)
    /// Badges, key caps, counts.
    static let micro = Font.system(size: 10, weight: .medium)

    /// Code, commands, paths, diffs.
    static let code = Font.system(size: 12, design: .monospaced)
    static let codeSmall = Font.system(size: 11, design: .monospaced)

    static let codeNS = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

// MARK: - Space and shape

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    /// Key caps, chips, small controls.
    static let control: CGFloat = 5
    /// Rows, fields, buttons, bubbles.
    static let row: CGFloat = 8
    /// Tiles, panels, popovers.
    static let pane: CGFloat = 12
}

enum Size {
    /// Tile headers and the canvas strip.
    static let barHeight: CGFloat = 30
    /// Icon-only buttons.
    static let iconButton: CGFloat = 22
    static let statusDot: CGFloat = 7
    static let avatar: CGFloat = 22
    /// An agent's logo, sized to sit on a name's line.
    static let mark: CGFloat = 16
    static let hairline: CGFloat = 1
    /// The window's titlebar band (there is no toolbar): the traffic lights sit in it.
    static let titlebar: CGFloat = 28
    /// How far the traffic lights reach into that band from the window's leading edge.
    static let trafficLights: CGFloat = 72
}

// MARK: - Color

/// Opaque sumi-ink layers, darkest at the back, faintly warm. AppKit colors for layers and windows.
enum Ink {
    /// Window and canvas: the deepest layer.
    static let floor = NSColor(srgbRed: 0.043, green: 0.041, blue: 0.039, alpha: 1)
    /// Sidebar and inspector.
    static let deep = NSColor(srgbRed: 0.066, green: 0.063, blue: 0.060, alpha: 1)
    /// Fields, cards, bars.
    static let surface = NSColor(srgbRed: 0.098, green: 0.094, blue: 0.090, alpha: 1)
    /// Hover and selection.
    static let raised = NSColor(srgbRed: 0.137, green: 0.131, blue: 0.125, alpha: 1)
    static let hairline = NSColor(srgbRed: 0.165, green: 0.158, blue: 0.150, alpha: 1)
    /// Night's chrome: near-black, see-through. Sidebar, inspector and canvas all take it, so
    /// they read as one sheet; tile headers sit on the canvas and show it.
    static let night = NSColor(srgbRed: 0.031, green: 0.031, blue: 0.031, alpha: 0.72)
    /// Bone, the interface's primary text color.
    static let text = NSColor(srgbRed: 0.929, green: 0.910, blue: 0.867, alpha: 1)
    static let muted = NSColor(srgbRed: 0.620, green: 0.600, blue: 0.565, alpha: 1)
    static let faint = NSColor(srgbRed: 0.420, green: 0.404, blue: 0.384, alpha: 1)
    /// Shu (vermilion), Tako's red: the one primary action in view, and the brand. Never
    /// focus or selection: red around a terminal reads as an error.
    static let accent = NSColor(srgbRed: 0.851, green: 0.290, blue: 0.200, alpha: 1)
    /// Where focus is: the focused tile, drop targets, a split being dragged. Bone, half strength.
    static let focus = NSColor(srgbRed: 0.929, green: 0.910, blue: 0.867, alpha: 0.5)
}

/// The same layers for SwiftUI.
enum Tone {
    static let floor = Color(nsColor: Ink.floor)
    static let deep = Color(nsColor: Ink.deep)
    static let surface = Color(nsColor: Ink.surface)
    static let raised = Color(nsColor: Ink.raised)
    static let hairline = Color(nsColor: Ink.hairline)
    static let text = Color(nsColor: Ink.text)
    static let muted = Color(nsColor: Ink.muted)
    static let faint = Color(nsColor: Ink.faint)
    static let focus = Color(nsColor: Ink.focus)
}

/// Meaning. These are the only saturated colors in the app.
enum Palette {
    static let accent = Color(nsColor: Ink.accent)
    /// An agent at work: ai (indigo), calm enough to sit on many rows at once.
    static let working = Color(nsColor: NSColor(srgbRed: 0.494, green: 0.612, blue: 0.788, alpha: 1))
    /// Something needs you: yamabuki (gold).
    static let attention = Color(nsColor: NSColor(srgbRed: 0.894, green: 0.647, blue: 0.247, alpha: 1))
    /// Beni (crimson), rosier than the vermilion accent so failure never reads as focus.
    static let failed = Color(nsColor: NSColor(srgbRed: 0.882, green: 0.345, blue: 0.443, alpha: 1))
    /// Live servers, passing tests, added lines: matcha.
    static let running = Color(nsColor: NSColor(srgbRed: 0.557, green: 0.749, blue: 0.494, alpha: 1))
    static let idle = Tone.faint
    /// Which agent it is: used only on the agent's own mark. Claude's coral, and OpenAI's mark in
    /// the text color, as each company draws it.
    static let claude = Color(nsColor: NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1))
    static var codex: Color { Tone.text }

    static func status(_ state: AgentState) -> Color {
        switch state {
        case .working, .starting: return working
        case .needsInput: return attention
        case .failed: return failed
        case .running: return running
        case .idle: return idle
        case .exited: return Tone.faint.opacity(0.5)
        }
    }
}

/// The window's two looks. The layout is the same in both; only colours, opacity and how the
/// window goes full screen differ.
enum WindowTheme: String, CaseIterable {
    /// Near-black chrome the desktop shows faintly through (with Ghostty's own `background-blur`
    /// if the user set one); full screen in place.
    case night
    /// Opaque sumi panels and native full screen.
    case original

    static let defaultsKey = "windowTheme"

    var title: String { self == .night ? "Night" : "Original" }

    /// See-through window, full screen in place (native full screen would put it on a black Space).
    var isTranslucent: Bool { self == .night }

    /// Sidebar and inspector.
    var paneFill: NSColor { self == .night ? Ink.night : Ink.deep }
    /// The canvas the tiles float on.
    var canvasFill: NSColor { self == .night ? Ink.night : Ink.floor }
    /// Tile headers and the backing under a terminal. Clear at night: the canvas shows through,
    /// so headers match the sidebar, and each terminal paints its own see-through background.
    func tileFill(terminal: NSColor) -> NSColor { self == .night ? .clear : terminal }
    /// Nearly clear rather than clear at night, so the window server still applies a blur.
    var windowFill: NSColor { self == .night ? .white.withAlphaComponent(0.001) : Ink.floor }

    static func load(from defaults: UserDefaults) -> WindowTheme {
        defaults.string(forKey: defaultsKey).flatMap(WindowTheme.init(rawValue:)) ?? .night
    }

    func save(to defaults: UserDefaults) { defaults.set(rawValue, forKey: Self.defaultsKey) }
}

/// The terminal's own colors, from the user's Ghostty theme, for surfaces that show terminal
/// content (diffs, previews) so they read as part of the terminal; and the window's theme.
@MainActor
enum Theme {
    static private(set) var terminalBackground = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    static private(set) var terminalForeground = NSColor(white: 0.9, alpha: 1)
    /// View › Theme. Changing it posts `.windowThemeChanged`; windows restyle in place.
    static private(set) var window = AppSettings.windowTheme

    static var isTranslucent: Bool { window.isTranslucent }

    static func setWindow(_ theme: WindowTheme) {
        guard theme != window else { return }
        window = theme
        AppSettings.windowTheme = theme
        NotificationCenter.default.post(name: .windowThemeChanged, object: nil)
    }

    static func load(from config: ghostty_config_t?) {
        guard let config else { return }
        if let bg = color(config, "background") { terminalBackground = bg }
        if let fg = color(config, "foreground") { terminalForeground = fg }
    }

    private static func color(_ config: ghostty_config_t, _ key: String) -> NSColor? {
        var value = ghostty_config_color_s()
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(value.r) / 255, green: CGFloat(value.g) / 255, blue: CGFloat(value.b) / 255, alpha: 1)
    }
}

// MARK: - Motion

enum Motion {
    static let standard: TimeInterval = 0.2
    static let quick: TimeInterval = 0.12

    @MainActor static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    @MainActor static func duration(_ base: TimeInterval) -> TimeInterval { reduced ? 0 : base }

    static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)

    /// SwiftUI: pass the view's `accessibilityReduceMotion`.
    static func animation(_ reduceMotion: Bool, _ base: TimeInterval = standard) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: base)
    }
}

// MARK: - Materials

extension View {
    /// Floating surfaces (the command palette, find bar, recap) are Liquid Glass on macOS 26
    /// when built with its SDK, and solid graphite otherwise.
    @ViewBuilder func floatingSurface(cornerRadius: CGFloat = Radius.pane, fallback: Color = Tone.surface) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // Tinted toward graphite so light text stays legible over any window behind it.
            self.glassEffect(.regular.tint(fallback.opacity(0.72)), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .environment(\.colorScheme, .dark)
        } else {
            self.background(fallback, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        #else
        self.background(fallback, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #endif
    }
}

// MARK: - Components

/// A choice between a few views or values, drawn in the app's own ink instead of AppKit's
/// gray segmented control. `.underline` for tabs that switch a panel's content (the inspector);
/// `.pill` for a compact value picker (Settings panes, Quick Ask's agent).
struct SegmentedTabs<Value: Hashable>: View {
    enum Style { case underline, pill }

    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var style: Style = .pill
    @Namespace private var marker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: style == .pill ? 0 : Space.l) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                segment(option.value, option.title)
            }
        }
        .padding(style == .pill ? Space.xxs : 0)
        .background {
            if style == .pill {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(Tone.surface)
                    .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Tone.hairline))
            }
        }
        .animation(Motion.animation(reduceMotion), value: selection)
        .accessibilityElement(children: .contain)
    }

    private func segment(_ value: Value, _ title: String) -> some View {
        let selected = value == selection
        return Button { selection = value } label: {
            Text(title)
                .font(Typeface.callout.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Tone.text : Tone.muted)
                .lineLimit(1)
                .padding(.horizontal, style == .pill ? Space.m : 0)
                .frame(minHeight: style == .pill ? 24 : 30)
                .frame(maxWidth: style == .pill ? .infinity : nil)
                .background {
                    if selected, style == .pill {
                        RoundedRectangle(cornerRadius: Radius.row - Space.xxs, style: .continuous)
                            .fill(Tone.raised)
                            .matchedGeometryEffect(id: "marker", in: marker)
                    }
                }
                .overlay(alignment: .bottom) {
                    if selected, style == .underline {
                        Capsule().fill(Palette.accent).frame(height: 2)
                            .matchedGeometryEffect(id: "marker", in: marker)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A thin meter: tasks done, context used. Turns gold past `warning`.
struct Meter: View {
    let fraction: Double
    var warning: Double = 2

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Tone.raised)
                .overlay(alignment: .leading) {
                    Capsule().fill(fraction >= warning ? Palette.attention : Tone.muted)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
        }
        .frame(height: 4)
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// A full-width action in a panel: icon, label, and a hover fill. Quieter than a button row
/// for lists of secondary actions.
struct ActionRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: symbol)
                    .font(Typeface.callout)
                    .foregroundStyle(Tone.muted)
                    .frame(width: 18)
                Text(title).font(Typeface.callout).foregroundStyle(Tone.text)
                Spacer(minLength: Space.xs)
                if let detail { Text(detail).font(Typeface.caption).foregroundStyle(Tone.faint) }
            }
            .padding(.horizontal, Space.s)
            .frame(minHeight: 28)
            .background(hovering ? Tone.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A key cap: "⌘N".
struct KeyboardHint: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(Typeface.micro.monospaced())
            .foregroundStyle(Tone.faint)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
            .background(Tone.raised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .fixedSize()
            .accessibilityLabel(keys)
    }
}

/// A plain section heading, in sentence case, the way Apple's sidebars and inspectors title
/// their groups.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Text(title).font(Typeface.caption.weight(.semibold)).foregroundStyle(Tone.muted).lineLimit(1)
            Spacer(minLength: Space.xs)
            trailing().font(Typeface.caption).foregroundStyle(Tone.faint)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Buttons in panels: a quiet fill that deepens on press. `prominent` is the one primary action.
struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = Palette.accent

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(label: configuration.label, pressed: configuration.isPressed, prominent: prominent, tint: tint)
    }
}

private struct PanelButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let prominent: Bool
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        label
            .font(Typeface.callout.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(prominent ? Tone.floor : Tone.text)
            .padding(.horizontal, Space.m)
            .frame(minHeight: 26)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }

    private var fill: Color {
        if prominent { return tint.opacity(pressed ? 0.75 : hovering ? 0.9 : 1) }
        return pressed ? Tone.hairline : hovering ? Tone.raised : Tone.surface
    }
}

/// Kept for call sites that predate the panel style.
typealias ChromeButtonStyle = PanelButtonStyle

/// An icon-only button that shows its fill only on hover, like a toolbar button.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Tone.muted
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Typeface.caption.weight(.semibold))
                .foregroundStyle(hovering ? Tone.text : tint)
                .frame(width: Size.iconButton, height: Size.iconButton)
                .background(hovering ? Tone.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A session's state as a dot: filled while something is happening, ringed while it needs you.
struct StatusDot: View {
    let state: AgentState
    var size: CGFloat = Size.statusDot

    var body: some View {
        Circle()
            .fill(Palette.status(state))
            .frame(width: size, height: size)
            .overlay {
                if state.needsAttention {
                    Circle().strokeBorder(Palette.attention.opacity(0.35), lineWidth: 2)
                        .frame(width: size + Space.xs + 1, height: size + Space.xs + 1)
                }
            }
            .frame(width: size + Space.xs + 1, height: size + Space.xs + 1)
            .accessibilityLabel(state.phrase)
    }
}

/// A sleeping agent: quiet, not a status that asks for anything.
struct AsleepMark: View {
    var body: some View {
        Image(systemName: "moon.zzz")
            .font(Typeface.caption)
            .foregroundStyle(Tone.faint)
            .accessibilityLabel("Asleep")
    }
}

/// A small rounded tag: "+128 −41", ":5173", "3 queued".
struct Tag: View {
    let text: String
    var tint: Color = Tone.muted
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? Typeface.micro.monospaced() : Typeface.micro)
            .foregroundStyle(tint)
            .padding(.horizontal, Space.xs + 1)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .lineLimit(1)
            .fixedSize()
    }
}

/// "+128 −41" in the diff colors.
struct DiffCount: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: Space.xs) {
            Text("+\(added)").foregroundStyle(Palette.running)
            Text("−\(removed)").foregroundStyle(Palette.failed)
        }
        .font(Typeface.micro.monospacedDigit())
        .accessibilityLabel("\(added) added, \(removed) removed")
    }
}

/// A centered message for an empty panel.
struct EmptyMessage: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(Typeface.title.weight(.light))
                .foregroundStyle(Tone.faint)
                .padding(.bottom, Space.xs)
            Text(title).font(Typeface.headline).foregroundStyle(Tone.text)
            Text(detail)
                .font(Typeface.callout)
                .foregroundStyle(Tone.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.xxl + Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A thin rule between regions.
struct Hairline: View {
    var body: some View { Rectangle().fill(Tone.hairline).frame(height: Size.hairline) }
}

/// Tako's mark: the app icon itself, so the two always match.
struct WaveMark: View {
    var body: some View {
        // Read from the bundle: NSApp.applicationIconImage can be a stale copy cached by macOS.
        Image(nsImage: Bundle.main.image(forResource: "AppIcon") ?? NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// One glyph language everywhere: agents are their own logos (Claude, OpenAI), everything else a
/// plain symbol.
struct KindMark: View {
    let kind: SessionKind
    var font: Font = Typeface.caption
    /// The logo's side; the same everywhere so marks line up across cards, tiles and lists.
    var size: CGFloat = Size.mark

    var body: some View {
        if let image = AgentMarkImage.image(for: kind) {
            Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
        } else if let letter = kind.monogram {
            Text(letter).font(font.weight(.bold)).fontDesign(.rounded)
        } else {
            Image(systemName: kind.symbol).font(font.weight(.medium))
        }
    }
}

/// The agent's own logo, as a single-color template image bundled under Resources/Mark. Without
/// the file the monogram letter is drawn instead.
enum AgentMarkImage {
    private static var cache: [SessionKind: NSImage?] = [:]

    static func image(for kind: SessionKind) -> NSImage? {
        if let cached = cache[kind] { return cached }
        let name: String? = { switch kind { case .claude: return "claude"; case .codex: return "openai"; default: return nil } }()
        let image = name.flatMap { Bundle.main.url(forResource: $0, withExtension: "png", subdirectory: "Mark") }
            .flatMap { NSImage(contentsOf: $0) }
        image?.isTemplate = true
        cache[kind] = image
        return image
    }
}

/// The agent's logo, bare, in its own color; other kinds keep the quiet square. State is shown by
/// the words and pill beside it, so the mark never changes color and nothing else competes.
struct AgentAvatar: View {
    let kind: SessionKind
    var dimmed = false

    var body: some View {
        let isAgent = AgentMarkImage.image(for: kind) != nil
        KindMark(kind: kind)
            .foregroundStyle(kind.tint.opacity(dimmed ? 0.45 : 1))
            // The avatar's column stays the same width, so rows below line up with the name.
            .frame(width: Size.avatar, height: Size.avatar)
            .background(isAgent ? Color.clear : Tone.surface, in: RoundedRectangle(cornerRadius: Radius.control + 1, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Icon tight against its title, as in Finder's status bars.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xs - 1) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

// MARK: - Vocabulary

extension SessionKind {
    var symbol: String {
        switch self {
        case .claude: return "c.square"
        case .codex: return "x.square"
        case .shell: return "terminal"
        case .server: return "bolt"
        case .browser: return "globe"
        }
    }

    /// Agents are drawn as a letter rather than a symbol.
    var monogram: String? {
        switch self {
        case .claude: return "C"
        case .codex: return "X"
        default: return nil
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Palette.claude
        case .codex: return Palette.codex
        case .shell, .server, .browser: return Tone.muted
        }
    }
}

extension AgentState {
    /// The one status vocabulary used everywhere: Working, Needs you, Done, Idle (+ Failed,
    /// Exited, Running for processes).
    var phrase: String {
        switch self {
        case .starting: return "Starting"
        case .working: return "Working"
        case .needsInput: return "Needs you"
        case .idle: return "Idle"
        case .failed: return "Failed"
        case .exited(let code): return code == 0 ? "Exited" : "Exit \(code)"
        case .running: return "Running"
        }
    }
}

extension TerminalSession {
    /// Idle after finishing a turn reads as "Done"; idle before any work reads as "Idle".
    var statusWord: String {
        if isAsleep { return "Asleep" }
        if isWaking { return "Waking…" }
        if state == .idle, summary != nil || !timeline.isEmpty { return "Done" }
        return state.phrase
    }
}

extension NSColor {
    var luminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }
}

func elapsed(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86_400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86_400)d"
}

extension Notification.Name {
    static let windowThemeChanged = Notification.Name("KuronamiWindowThemeChanged")
}

/// The canvas terminals float on: flat graphite.
final class InkCanvas: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @MainActor func applyTheme() { layer?.backgroundColor = Theme.window.canvasFill.cgColor }
}

/// Empty chrome the window is dragged by: the sidebar's top inset, the canvas's top edge.
/// Double-click zooms or minimizes, as the system setting says.
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window, window.isMovable else { return }
        guard event.clickCount == 2 else { window.performDrag(with: event); return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// `WindowDragView` behind SwiftUI content.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {}
}

// MARK: - Sumi

extension Size {
    /// Sumi CLI's badge in the corner of the Tako mark.
    static let markBadge: CGFloat = 14
}

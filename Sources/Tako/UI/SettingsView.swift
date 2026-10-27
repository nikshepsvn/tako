import AppKit
import SwiftUI

/// Preferences that aren't a property of any one agent.
enum AppSettings {
    private static let defaults = UserDefaults.standard

    /// ⌃⌥Space opens Quick Ask from any app.
    static var quickAskEnabled: Bool {
        get { defaults.object(forKey: "quickAskEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "quickAskEnabled"); NotificationCenter.default.post(name: .quickAskSettingChanged, object: nil) }
    }

    /// Snapshots at every turn boundary, for per-turn diffs and reverting files.
    static var checkpointsEnabled: Bool {
        get { defaults.object(forKey: "checkpointsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "checkpointsEnabled") }
    }

    /// The steward quits idle agents' CLIs to free memory, resuming them on the next message.
    /// On for new installs; off for people upgrading, so agents they left idle aren't quit unasked.
    static var autoSleepEnabled: Bool {
        get { defaults.object(forKey: "autoSleepEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoSleepEnabled") }
    }

    /// Fixes the auto-sleep default once, before the first launch writes any session state.
    static func settleAutoSleepDefault(existingInstall: Bool) {
        guard defaults.object(forKey: "autoSleepEnabled") == nil else { return }
        defaults.set(!existingInstall, forKey: "autoSleepEnabled")
    }

    /// The permission mode new agents start with; nil leaves each CLI's own setting in charge.
    static var defaultMode: PermissionMode? {
        get { defaults.string(forKey: "defaultPermissionMode").flatMap(PermissionMode.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: "defaultPermissionMode") }
    }

    /// View › Theme. Read once at launch through `Theme.window`, which is what changes it.
    static var windowTheme: WindowTheme {
        get { .load(from: defaults) }
        set { newValue.save(to: defaults) }
    }
}

extension Notification.Name {
    static let quickAskSettingChanged = Notification.Name("KuronamiQuickAskSettingChanged")
}

struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", accounts = "Accounts", integrations = "Integrations"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .accounts: return "person.crop.circle"
            case .integrations: return "puzzlepiece.extension"
            }
        }
    }

    @State var pane: Pane
    let signIn: (AgentAccount) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SegmentedTabs(options: Pane.allCases.map { ($0, $0.rawValue) }, selection: $pane)
                .frame(width: 360)
            .padding(.vertical, Space.m)
            Hairline()
            switch pane {
            case .general: GeneralSettings()
            case .accounts: AccountsView(accounts: AccountStore.shared, signIn: signIn)
            case .integrations: IntegrationSettings()
            }
        }
        .frame(width: 560)
        .foregroundStyle(Tone.text)
        .background(Tone.floor)
        .tint(Palette.accent)
    }
}

private struct GeneralSettings: View {
    @State private var quickAsk = AppSettings.quickAskEnabled
    @State private var checkpoints = AppSettings.checkpointsEnabled
    @State private var autoSleep = AppSettings.autoSleepEnabled
    @State private var mode = AppSettings.defaultMode
    @State private var editor = Editors.preferred?.id ?? ""
    @AppStorage(SessionStore.sumiKindKey, store: SessionStore.sumiDefaults) private var sumiRaw: String?
    @ObservedObject private var installed = InstalledAgents.shared

    /// Shared with Sumi panel's header: a running sumi restarts on the new CLI.
    private var sumiKind: Binding<SessionKind?> {
        Binding(get: { TerminalSessionFactory.store?.sumi?.kind ?? SessionStore.sumiKind }, set: { kind in
            guard let kind else { return }
            if let store = TerminalSessionFactory.store, store.sumi != nil {
                store.switchSumi(to: kind)
            } else {
                SessionStore.sumiKind = kind
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            setting("New agents start with", detail: mode?.detail ?? "Each agent uses its own permission settings.") {
                Picker("", selection: $mode) {
                    Text("Their Own Settings").tag(PermissionMode?.none)
                    Divider()
                    ForEach(PermissionMode.allCases) { Text($0.title).tag(PermissionMode?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: mode) { AppSettings.defaultMode = mode }
            }
            setting("Open workspaces in", detail: "Used by Open in Editor (⌥⌘O), the toolbar, and file menus.") {
                Picker("", selection: $editor) {
                    if Editors.installed.isEmpty { Text("Finder").tag("") }
                    ForEach(Editors.installed) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: editor) { UserDefaults.standard.set(editor, forKey: "preferredEditor") }
            }
            setting("Run Sumi with", detail: "Switching restarts it in its own folder. Its notes file carries over, so it keeps what it learned.") {
                Picker("", selection: sumiKind) {
                    if sumiKind.wrappedValue == nil { Text("Not Chosen").tag(SessionKind?.none) }
                    ForEach(SessionStore.sumiChoices) { kind in
                        Text(installed.isInstalled(kind) ? kind.displayName : kind.displayName + " (not installed)")
                            .tag(SessionKind?.some(kind))
                            .selectionDisabled(!installed.isInstalled(kind))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onAppear { installed.refresh() }
            }
            Hairline()
            setting("Quick Ask with ⌃⌥Space", detail: "Start an agent from any app without switching to Tako.") {
                Toggle("", isOn: $quickAsk).labelsHidden()
                    .onChange(of: quickAsk) { AppSettings.quickAskEnabled = quickAsk }
            }
            setting("Checkpoint every turn", detail: "Hidden Git snapshots power per-turn diffs and reverting files. Your index, branches and stash are never touched.") {
                Toggle("", isOn: $checkpoints).labelsHidden()
                    .onChange(of: checkpoints) { AppSettings.checkpointsEnabled = checkpoints }
            }
            setting("Put idle agents to sleep", detail: "After 10 quiet minutes an agent's CLI quits to free memory; the next message wakes it in the same conversation. Agents with background tasks stay awake.") {
                Toggle("", isOn: $autoSleep).labelsHidden()
                    .onChange(of: autoSleep) { AppSettings.autoSleepEnabled = autoSleep }
            }
        }
        .toggleStyle(.switch)
        .padding(Space.xl)
    }

    private func setting<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.l) {
            label(title, detail: detail)
            Spacer(minLength: Space.m)
            control()
        }
    }

    private func label(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(Typeface.body)
            Text(detail).font(Typeface.caption).foregroundStyle(Tone.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct IntegrationSettings: View {
    @State private var outsideChrome = AgentBrowser.agentsMayUseOutsideChrome

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            row("Let agents use my Chrome", detail: "Off: agents browse only in Tako's browsers. On: Claude agents may also use your own Chrome through Claude in Chrome.") {
                Toggle("", isOn: $outsideChrome)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: outsideChrome) {
                        AgentBrowser.agentsMayUseOutsideChrome = outsideChrome
                        AgentIntegration.install()
                    }
            }
            Hairline()
            row("ht in your shell", detail: "Script Tako from any terminal: ht ls, ht send, ht new.") {
                Button("Set Up…") { NSApp.sendAction(#selector(AppDelegate.installCLI(_:)), to: nil, from: nil) }
            }
            Text("Claude channels are in the Tako menu.").font(Typeface.caption).foregroundStyle(Tone.faint)
        }
        .buttonStyle(PanelButtonStyle())
        .padding(Space.xl)
    }

    private func row<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(Typeface.body)
                Text(detail).font(Typeface.caption).foregroundStyle(Tone.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.m)
            control()
        }
    }
}

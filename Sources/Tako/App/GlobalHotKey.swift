import Carbon

/// A system-wide shortcut through Carbon's hot key API, which needs no Accessibility
/// permission and only ever sees its own key combination.
final class GlobalHotKey: @unchecked Sendable {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// ⌃⌥Space.
    static let quickAsk = (keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { hotKey.action() } }
            return noErr
        }, 1, &spec, context, &handler)
        guard installed == noErr else { return nil }
        // 'KURN'
        let id = EventHotKeyID(signature: OSType(0x4B55_524E), id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr else { return nil }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

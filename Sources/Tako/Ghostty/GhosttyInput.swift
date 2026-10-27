// Adapted from Ghostty's macOS Ghostty.Input.swift and NSEvent+Extension.swift
// (https://github.com/ghostty-org/ghostty, MIT License).

import AppKit
import Carbon
import GhosttyKit

enum GhosttyInput {
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// Text fields and the unshifted codepoint are filled per call site because C string
    /// lifetimes can't outlive this function.
    static func keyEvent(_ event: NSEvent, action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.composing = false
        key.mods = mods(event.modifierFlags)
        // Heuristic from Ghostty: control and command never contribute to producing text.
        key.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    /// Text to send for a key event, leaving control characters and function-key PUA codepoints
    /// for libghostty's encoder.
    static func characters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    /// Applies config such as macos-option-as-alt by rebuilding the event with translation mods.
    /// The original event must be reused when nothing changed, or IMEs like Korean break.
    static func translationEvent(for event: NSEvent, surface: ghostty_surface_t) -> NSEvent {
        let translated = flags(ghostty_surface_key_translation_mods(surface, mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        guard translationMods != event.modifierFlags else { return event }
        return NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    static func modifierBit(forKeyCode keyCode: UInt16) -> UInt32? {
        switch keyCode {
        case 0x39: return GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: return GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: return GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: return GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: return GHOSTTY_MODS_SUPER.rawValue
        default: return nil
        }
    }

    static func isSidePressed(_ event: NSEvent) -> Bool {
        let raw = event.modifierFlags.rawValue
        switch event.keyCode {
        case 0x3C: return raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
        case 0x3E: return raw & UInt(NX_DEVICERCTLKEYMASK) != 0
        case 0x3D: return raw & UInt(NX_DEVICERALTKEYMASK) != 0
        case 0x36: return raw & UInt(NX_DEVICERCMDKEYMASK) != 0
        default: return true
        }
    }

    static func scrollMods(precise: Bool, phase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        let momentum: Int32
        switch phase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        return (precise ? 1 : 0) | (momentum << 1)
    }

    static func keyboardLayoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

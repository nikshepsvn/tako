import Carbon

/// Key names accepted by `ht key`, mapped to macOS virtual key codes.
struct NamedKey {
    let keyCode: Int
    let text: String
    let control: Bool
    var shift = false
    var alt = false

    private static let special: [String: (Int, String)] = [
        "enter": (kVK_Return, "\r"), "return": (kVK_Return, "\r"),
        "esc": (kVK_Escape, "\u{1b}"), "escape": (kVK_Escape, "\u{1b}"),
        "tab": (kVK_Tab, "\t"), "space": (kVK_Space, " "),
        "backspace": (kVK_Delete, "\u{7f}"), "delete": (kVK_ForwardDelete, ""),
        "up": (kVK_UpArrow, ""), "down": (kVK_DownArrow, ""),
        "left": (kVK_LeftArrow, ""), "right": (kVK_RightArrow, ""),
        "home": (kVK_Home, ""), "end": (kVK_End, ""),
        "pageup": (kVK_PageUp, ""), "pagedown": (kVK_PageDown, ""),
    ]

    private static let letters: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8,
        "9": kVK_ANSI_9,
    ]

    /// "enter", "y", or any of those behind modifiers: "ctrl-c", "shift-tab", "alt-enter", "ctrl-shift-z".
    init?(_ raw: String) {
        var name = raw.lowercased().replacingOccurrences(of: "+", with: "-")
        var control = false, shift = false, alt = false
        while let prefix = ["ctrl-", "control-", "shift-", "alt-", "option-", "opt-"].first(where: name.hasPrefix), name.count > prefix.count {
            name.removeFirst(prefix.count)
            switch prefix {
            case "ctrl-", "control-": control = true
            case "shift-": shift = true
            default: alt = true
            }
        }
        if name == "backtab" { name = "tab"; shift = true }
        if let (code, text) = Self.special[name] {
            self.init(keyCode: code, text: text, control: control, shift: shift, alt: alt)
        } else if name.count == 1, let char = name.first, let code = Self.letters[char] {
            self.init(keyCode: code, text: shift && !control ? String(char).uppercased() : String(char), control: control, shift: shift, alt: alt)
        } else {
            return nil
        }
    }

    private init(keyCode: Int, text: String, control: Bool, shift: Bool, alt: Bool) {
        self.keyCode = keyCode
        self.text = text
        self.control = control
        self.shift = shift
        self.alt = alt
    }
}

import CoreGraphics
import Foundation

/// Parses xdotool-style key specs ("super+shift+t", "Return", "KP_0", "ctrl+Page_Down") into a
/// macOS virtual key code plus modifier flags.
struct KeyCombo {
    var keyCode: CGKeyCode
    var flags: CGEventFlags
    var modifierKeyCodes: [(CGKeyCode, CGEventFlags)]
}

enum KeySyntax {
    static let modifiers: [String: (CGKeyCode, CGEventFlags)] = [
        "super": (55, .maskCommand), "cmd": (55, .maskCommand), "command": (55, .maskCommand),
        "meta": (55, .maskCommand), "win": (55, .maskCommand), "mod4": (55, .maskCommand),
        "ctrl": (59, .maskControl), "control": (59, .maskControl), "control_l": (59, .maskControl), "control_r": (62, .maskControl),
        "alt": (58, .maskAlternate), "option": (58, .maskAlternate), "opt": (58, .maskAlternate), "alt_l": (58, .maskAlternate), "alt_r": (61, .maskAlternate),
        "shift": (56, .maskShift), "shift_l": (56, .maskShift), "shift_r": (60, .maskShift),
        "super_l": (55, .maskCommand), "super_r": (54, .maskCommand), "meta_l": (55, .maskCommand),
        "fn": (63, .maskSecondaryFn),
    ]

    static let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "kp_enter": 76, "linefeed": 36,
        "tab": 48, "iso_left_tab": 48, "space": 49, "backspace": 51, "delete": 117, "del": 117,
        "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "page_up": 116, "prior": 116, "pageup": 116,
        "page_down": 121, "next": 121, "pagedown": 121, "insert": 114, "help": 114,
        "caps_lock": 57, "capslock": 57, "clear": 71, "kp_clear": 71,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "kp_0": 82, "kp_1": 83, "kp_2": 84, "kp_3": 85, "kp_4": 86, "kp_5": 87, "kp_6": 88,
        "kp_7": 89, "kp_8": 91, "kp_9": 92, "kp_decimal": 65, "kp_separator": 65, "kp_add": 69,
        "kp_subtract": 78, "kp_multiply": 67, "kp_divide": 75, "kp_equal": 81,
        "minus": 27, "equal": 24, "bracketleft": 33, "bracketright": 30, "backslash": 42,
        "semicolon": 41, "apostrophe": 39, "quoteright": 39, "grave": 50, "quoteleft": 50,
        "comma": 43, "period": 47, "slash": 44,
        "volumeup": 72, "volumedown": 73, "mute": 74,
    ]

    /// Shifted names that map to a base key + shift.
    static let shiftedNamed: [String: CGKeyCode] = [
        "plus": 24, "underscore": 27, "braceleft": 33, "braceright": 30, "bar": 42, "colon": 41,
        "quotedbl": 39, "asciitilde": 50, "less": 43, "greater": 47, "question": 44,
        "exclam": 18, "at": 19, "numbersign": 20, "dollar": 21, "percent": 23, "asciicircum": 22,
        "ampersand": 26, "asterisk": 28, "parenleft": 25, "parenright": 29,
    ]

    static let chars: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]

    static let shiftedChars: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "~": "`", "<": ",", ">": ".", "?": "/",
    ]

    static func parse(_ spec: String) throws -> KeyCombo {
        var raw = spec.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { throw ToolError("Empty key.") }
        // A literal "+" key (e.g. "super++" or "+") — split carefully.
        var tokens: [String] = []
        if raw == "+" {
            tokens = ["plus"]
        } else {
            if raw.hasSuffix("++") { raw = String(raw.dropLast(2)) + "+plus" }
            tokens = raw.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        }
        guard let keyToken = tokens.last else { throw ToolError("Invalid key: \(spec)") }

        var flags: CGEventFlags = []
        var mods: [(CGKeyCode, CGEventFlags)] = []
        for t in tokens.dropLast() {
            guard let m = modifiers[t.lowercased()] else {
                throw ToolError("Unknown modifier \"\(t)\" in \"\(spec)\". Use super/cmd, ctrl, alt/option, shift, fn.")
            }
            if !flags.contains(m.1) { mods.append(m) }
            flags.insert(m.1)
        }

        func addShift() {
            if !flags.contains(.maskShift) { mods.append((56, .maskShift)) }
            flags.insert(.maskShift)
        }

        let lower = keyToken.lowercased()
        var code: CGKeyCode?
        if let m = modifiers[lower], tokens.count == 1 {
            return KeyCombo(keyCode: m.0, flags: m.1, modifierKeyCodes: [])
        }
        if let c = named[lower] {
            code = c
        } else if let c = shiftedNamed[lower] {
            code = c
            addShift()
        } else if keyToken.count == 1, let ch = keyToken.first {
            if let c = chars[ch] {
                code = c
            } else if ch.isUppercase, let c = chars[Character(ch.lowercased())] {
                code = c
                addShift()
            } else if let base = shiftedChars[ch], let c = chars[base] {
                code = c
                addShift()
            }
        }
        guard let keyCode = code else {
            throw ToolError("Unknown key \"\(keyToken)\". Examples: a, Return, Tab, Escape, BackSpace, Delete, Up, Page_Down, F5, KP_0, super+c.")
        }
        // Arrow / navigation / function keys carry these flags when typed on a real keyboard.
        if (115...126).contains(keyCode) || [96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122].contains(keyCode) {
            flags.insert(.maskSecondaryFn)
        }
        if (123...126).contains(keyCode) { flags.insert(.maskNumericPad) }
        if (65...92).contains(keyCode), [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92].contains(keyCode) {
            flags.insert(.maskNumericPad)
        }
        return KeyCombo(keyCode: keyCode, flags: flags, modifierKeyCodes: mods)
    }

    /// Modifier flags for click modifiers ("super", "shift+alt").
    static func modifierFlags(_ spec: String?) throws -> CGEventFlags {
        guard let spec, !spec.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var flags: CGEventFlags = []
        for t in spec.split(separator: "+").map({ String($0).lowercased().trimmingCharacters(in: .whitespaces) }) where !t.isEmpty {
            guard let m = modifiers[t] else { throw ToolError("Unknown modifier \"\(t)\" for click. Use super, ctrl, alt, shift.") }
            flags.insert(m.1)
        }
        return flags
    }
}

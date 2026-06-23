import Carbon.HIToolbox

enum ShortcutFormatter {
    private static let keyCodeToString: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "N", 45: "M", 46: ".", 47: "/", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        115: "Home", 116: "PgUp", 117: "Fwd Del", 119: "End",
        121: "PgDn", 114: "Help",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        65: "Num .", 67: "Num *", 69: "Num +", 71: "Num Clear",
        75: "Num /", 76: "Num Enter", 78: "Num -", 81: "Num =",
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3",
        86: "Num 4", 87: "Num 5", 88: "Num 6", 89: "Num 7",
        91: "Num 8", 92: "Num 9"
    ]

    static func format(keyCode: Int, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += keyCodeToString[UInt16(keyCode)] ?? "Key \(keyCode)"
        return s
    }
}

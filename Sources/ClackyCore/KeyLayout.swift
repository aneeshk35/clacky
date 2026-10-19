/// How a key sounds, based on its size and whether it has a stabilizer.
public enum KeyCategory: String, CaseIterable, Sendable {
    case standard, modifier, enter, backspace, space
}

public enum KeyPhase: String, CaseIterable, Sendable {
    case down, up
}

/// Maps macOS virtual key codes (Carbon `kVK_*`) to key categories and stereo positions.
public enum KeyLayout {
    public static func category(for keyCode: Int) -> KeyCategory {
        switch keyCode {
        case 49: return .space
        case 36, 76: return .enter          // return, keypad enter
        case 51, 117: return .backspace     // delete, forward delete
        case 54...63: return .modifier      // command, shift, caps lock, option, control, fn
        default: return .standard
        }
    }

    /// Where the key sits on the keyboard, from -1 (left edge) to 1 (right edge).
    public static func pan(for keyCode: Int) -> Float {
        guard let column = columns[keyCode] else { return 0 }
        return Float(max(-1, min(1, column / 7.5 - 1)))
    }

    /// Key centers, in key widths from the left edge of a 15-unit Mac ANSI layout.
    private static let columns: [Int: Double] = {
        var map: [Int: Double] = [:]
        func row(_ keys: [(Int, Double)]) { for (code, x) in keys { map[code] = x } }
        // esc, F1–F12
        row([(53, 0.5), (122, 1.5), (120, 2.5), (99, 3.5), (118, 4.5), (96, 5.5), (97, 6.5),
             (98, 7.5), (100, 8.5), (101, 9.5), (109, 10.5), (103, 11.5), (111, 12.5)])
        // ` 1 2 3 4 5 6 7 8 9 0 - = delete
        row([(50, 0.5), (18, 1.5), (19, 2.5), (20, 3.5), (21, 4.5), (23, 5.5), (22, 6.5), (26, 7.5),
             (28, 8.5), (25, 9.5), (29, 10.5), (27, 11.5), (24, 12.5), (51, 14)])
        // tab q w e r t y u i o p [ ] \
        row([(48, 0.75), (12, 2), (13, 3), (14, 4), (15, 5), (17, 6), (16, 7), (32, 8), (34, 9),
             (31, 10), (35, 11), (33, 12), (30, 13), (42, 14.25)])
        // caps a s d f g h j k l ; ' return
        row([(57, 0.875), (0, 2.25), (1, 3.25), (2, 4.25), (3, 5.25), (5, 6.25), (4, 7.25), (38, 8.25),
             (40, 9.25), (37, 10.25), (41, 11.25), (39, 12.25), (36, 13.875)])
        // shift z x c v b n m , . / right shift
        row([(56, 1.125), (6, 2.75), (7, 3.75), (8, 4.75), (9, 5.75), (11, 6.75), (45, 7.75), (46, 8.75),
             (43, 9.75), (47, 10.75), (44, 11.75), (60, 13.625)])
        // fn control option command space command option control, arrows
        row([(63, 0.5), (59, 1.5), (58, 2.5), (55, 3.625), (49, 7), (54, 10.375), (61, 11.5), (62, 12.5),
             (123, 12.5), (126, 13.5), (125, 13.5), (124, 14.5)])
        // Navigation cluster and keypad sit past the right edge.
        for code in [114, 115, 116, 117, 119, 121, 65, 67, 69, 71, 75, 76, 78, 81] + Array(82...89) + [91, 92] {
            map[code] = 15
        }
        return map
    }()
}

import AppKit

/// Parses text containing ANSI escape sequences (SGR codes) and produces
/// an `NSAttributedString` with appropriate colors and styles.
///
/// Supports:
/// - Standard 8 foreground/background colors (30-37, 40-47)
/// - Bright foreground/background colors (90-97, 100-107)
/// - 256 color mode (38;5;n / 48;5;n)
/// - 24-bit true color (38;2;r;g;b / 48;2;r;g;b)
/// - Bold, dim, italic, underline, strikethrough
/// - Reset
enum ANSIParser {

    // MARK: - Public

    /// Parse `text` containing ANSI escape sequences into an attributed string
    /// using the given base font and colors.
    static func attributedString(
        from text: String,
        font: NSFont,
        defaultForeground: NSColor = .labelColor,
        defaultBackground: NSColor = .clear
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var state = SGRState(foreground: defaultForeground, background: defaultBackground)
        let baseAttributes = makeAttributes(font: font, state: state)

        // Match ESC [ <params> m
        let pattern = "\u{1B}\\[([0-9;]*)m"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            // Fallback: return plain text
            return NSAttributedString(string: text, attributes: baseAttributes)
        }

        let nsText = text as NSString
        var cursor = 0

        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match else { return }
            let matchRange = match.range

            // Append text before this escape sequence
            if matchRange.location > cursor {
                let plainRange = NSRange(location: cursor, length: matchRange.location - cursor)
                let chunk = nsText.substring(with: plainRange)
                let attrs = makeAttributes(font: font, state: state)
                result.append(NSAttributedString(string: chunk, attributes: attrs))
            }

            // Parse the SGR parameters
            let paramsString = nsText.substring(with: match.range(at: 1))
            let params = paramsString.isEmpty ? [0] : paramsString.split(separator: ";").compactMap { Int($0) }
            applySGR(params: params, to: &state, defaultForeground: defaultForeground, defaultBackground: defaultBackground)

            cursor = matchRange.location + matchRange.length
        }

        // Append remaining text after last escape
        if cursor < nsText.length {
            let remaining = nsText.substring(from: cursor)
            let attrs = makeAttributes(font: font, state: state)
            result.append(NSAttributedString(string: remaining, attributes: attrs))
        }

        return result
    }

    // MARK: - SGR State

    private struct SGRState {
        var foreground: NSColor
        var background: NSColor
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var strikethrough = false
    }

    // MARK: - Attribute Construction

    private static func makeAttributes(font: NSFont, state: SGRState) -> [NSAttributedString.Key: Any] {
        var resolvedFont = font
        if state.bold {
            resolvedFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if state.italic {
            resolvedFont = NSFontManager.shared.convert(resolvedFont, toHaveTrait: .italicFontMask)
        }

        var fg = state.foreground
        if state.dim {
            fg = fg.withAlphaComponent(0.5)
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolvedFont,
            .foregroundColor: fg,
        ]
        if state.background != .clear {
            attrs[.backgroundColor] = state.background
        }
        if state.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if state.strikethrough {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    // MARK: - SGR Parsing

    private static func applySGR(
        params: [Int],
        to state: inout SGRState,
        defaultForeground: NSColor,
        defaultBackground: NSColor
    ) {
        var i = 0
        while i < params.count {
            let code = params[i]
            switch code {
            case 0:
                // Reset
                state = SGRState(foreground: defaultForeground, background: defaultBackground)
            case 1:
                state.bold = true
            case 2:
                state.dim = true
            case 3:
                state.italic = true
            case 4:
                state.underline = true
            case 9:
                state.strikethrough = true
            case 22:
                state.bold = false
                state.dim = false
            case 23:
                state.italic = false
            case 24:
                state.underline = false
            case 29:
                state.strikethrough = false
            case 30...37:
                state.foreground = standardColor(code - 30)
            case 38:
                // Extended foreground
                if let (color, advance) = parseExtendedColor(params: params, startingAt: i + 1) {
                    state.foreground = color
                    i += advance
                }
            case 39:
                state.foreground = defaultForeground
            case 40...47:
                state.background = standardColor(code - 40)
            case 48:
                // Extended background
                if let (color, advance) = parseExtendedColor(params: params, startingAt: i + 1) {
                    state.background = color
                    i += advance
                }
            case 49:
                state.background = defaultBackground
            case 90...97:
                state.foreground = brightColor(code - 90)
            case 100...107:
                state.background = brightColor(code - 100)
            default:
                break
            }
            i += 1
        }
    }

    /// Parse `5;n` (256 color) or `2;r;g;b` (truecolor) after code 38/48.
    /// Returns the color and how many extra indices were consumed.
    private static func parseExtendedColor(params: [Int], startingAt idx: Int) -> (NSColor, Int)? {
        guard idx < params.count else { return nil }
        let mode = params[idx]
        switch mode {
        case 5:
            // 256-color mode
            guard idx + 1 < params.count else { return nil }
            let n = params[idx + 1]
            return (color256(n), 2)
        case 2:
            // 24-bit RGB
            guard idx + 3 < params.count else { return nil }
            let r = CGFloat(params[idx + 1]) / 255
            let g = CGFloat(params[idx + 2]) / 255
            let b = CGFloat(params[idx + 3]) / 255
            return (NSColor(calibratedRed: r, green: g, blue: b, alpha: 1), 4)
        default:
            return nil
        }
    }

    // MARK: - Color Tables

    private static func standardColor(_ index: Int) -> NSColor {
        switch index {
        case 0: return NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 1)       // Black
        case 1: return NSColor(calibratedRed: 0.8, green: 0.0, blue: 0.0, alpha: 1)       // Red
        case 2: return NSColor(calibratedRed: 0.0, green: 0.7, blue: 0.0, alpha: 1)       // Green
        case 3: return NSColor(calibratedRed: 0.8, green: 0.7, blue: 0.0, alpha: 1)       // Yellow
        case 4: return NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.9, alpha: 1)       // Blue
        case 5: return NSColor(calibratedRed: 0.7, green: 0.3, blue: 0.8, alpha: 1)       // Magenta
        case 6: return NSColor(calibratedRed: 0.0, green: 0.7, blue: 0.7, alpha: 1)       // Cyan
        case 7: return NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.75, alpha: 1)    // White
        default: return .labelColor
        }
    }

    private static func brightColor(_ index: Int) -> NSColor {
        switch index {
        case 0: return NSColor(calibratedRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)       // Bright Black (Gray)
        case 1: return NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.3, alpha: 1)       // Bright Red
        case 2: return NSColor(calibratedRed: 0.3, green: 1.0, blue: 0.3, alpha: 1)       // Bright Green
        case 3: return NSColor(calibratedRed: 1.0, green: 1.0, blue: 0.3, alpha: 1)       // Bright Yellow
        case 4: return NSColor(calibratedRed: 0.4, green: 0.6, blue: 1.0, alpha: 1)       // Bright Blue
        case 5: return NSColor(calibratedRed: 1.0, green: 0.4, blue: 1.0, alpha: 1)       // Bright Magenta
        case 6: return NSColor(calibratedRed: 0.3, green: 1.0, blue: 1.0, alpha: 1)       // Bright Cyan
        case 7: return NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)       // Bright White
        default: return .labelColor
        }
    }

    /// Map a 256-color index to an NSColor.
    private static func color256(_ n: Int) -> NSColor {
        switch n {
        case 0...7:
            return standardColor(n)
        case 8...15:
            return brightColor(n - 8)
        case 16...231:
            // 6x6x6 color cube
            let adjusted = n - 16
            let r = CGFloat(adjusted / 36) / 5.0
            let g = CGFloat((adjusted % 36) / 6) / 5.0
            let b = CGFloat(adjusted % 6) / 5.0
            return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
        case 232...255:
            // Grayscale ramp
            let gray = CGFloat(n - 232) / 23.0
            return NSColor(calibratedWhite: gray, alpha: 1)
        default:
            return .labelColor
        }
    }
}

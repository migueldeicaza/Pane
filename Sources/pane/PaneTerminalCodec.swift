import Foundation
import SwiftTerm

enum PaneAnsi {
    static let escape = "\u{1b}["

    static func sgr(for attribute: PaneAttribute) -> String {
        var codes: [String] = ["0"]
        let style = CharacterStyle(rawValue: attribute.style)
        if style.contains(.bold) { codes.append("1") }
        if style.contains(.dim) { codes.append("2") }
        if style.contains(.italic) { codes.append("3") }
        if style.contains(.underline) { codes.append("4") }
        if style.contains(.blink) { codes.append("5") }
        if style.contains(.inverse) { codes.append("7") }
        if style.contains(.invisible) { codes.append("8") }
        if style.contains(.crossedOut) { codes.append("9") }
        codes.append(contentsOf: colorCodes(foreground: attribute.foreground))
        codes.append(contentsOf: colorCodes(background: attribute.background))
        return escape + codes.joined(separator: ";") + "m"
    }

    static func moveCursor(row: Int, col: Int) -> String {
        "\(escape)\(row);\(col)H"
    }

    static func clearScreen() -> String {
        "\(escape)2J"
    }

    static func clearLine() -> String {
        "\(escape)2K"
    }

    private static func colorCodes(foreground color: PaneColor) -> [String] {
        colorCodes(color, prefix: "38")
    }

    private static func colorCodes(background color: PaneColor) -> [String] {
        colorCodes(color, prefix: "48")
    }

    private static func colorCodes(_ color: PaneColor, prefix: String) -> [String] {
        switch color {
        case .defaultColor:
            return [prefix == "38" ? "39" : "49"]
        case .defaultInvertedColor:
            return [prefix == "38" ? "39" : "49"]
        case .ansi(let code):
            return [prefix, "5", "\(code)"]
        case .trueColor(let r, let g, let b):
            return [prefix, "2", "\(r)", "\(g)", "\(b)"]
        }
    }
}

extension PaneColor {
    init(_ color: SwiftTerm.Attribute.Color) {
        switch color {
        case .ansi256(let code):
            self = .ansi(code)
        case .trueColor(let red, let green, let blue):
            self = .trueColor(red, green, blue)
        case .defaultColor:
            self = .defaultColor
        case .defaultInvertedColor:
            self = .defaultInvertedColor
        }
    }
}

extension PaneAttribute {
    init(_ attribute: SwiftTerm.Attribute) {
        self.foreground = PaneColor(attribute.fg)
        self.background = PaneColor(attribute.bg)
        self.style = attribute.style.rawValue
        self.underlineColor = attribute.underlineColor.map(PaneColor.init)
    }
}

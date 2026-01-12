import Foundation

final class PaneConsoleRenderer {
    private let driver: ConsoleDriver
    private var mapper: PaneAttributeMapper

    init(driver: ConsoleDriver) {
        self.driver = driver
        self.mapper = PaneAttributeMapper(driver: driver)
        Application.setDriver(driver)
    }

    func render(snapshot: PaneTerminalSnapshot) {
        let maxCols = min(driver.size.width, snapshot.cols)
        let maxRows = min(driver.size.height, snapshot.rows)
        if maxCols <= 0 || maxRows <= 0 {
            return
        }
        for row in 0..<maxRows {
            let line = snapshot.lines[row]
            drawLine(line, row: row, maxCols: maxCols)
        }
        driver.moveTo(col: min(snapshot.cursorX, maxCols - 1), row: min(snapshot.cursorY, maxRows - 1))
        driver.updateScreen()
    }

    func render(delta: PaneTerminalDelta) {
        let maxCols = min(driver.size.width, delta.lines.first?.count ?? driver.size.width)
        let maxRows = driver.size.height
        if maxCols <= 0 || maxRows <= 0 {
            return
        }
        let start = max(0, delta.startY)
        let end = min(maxRows - 1, delta.endY)
        if end < start {
            return
        }
        for (offset, line) in delta.lines.enumerated() {
            let row = start + offset
            if row > end { break }
            drawLine(line, row: row, maxCols: maxCols)
        }
        driver.moveTo(col: min(delta.cursorX, maxCols - 1), row: min(delta.cursorY, maxRows - 1))
        driver.updateScreen()
    }

    func end() {
        driver.end()
    }

    private func drawLine(_ cells: [PaneCell], row: Int, maxCols: Int) {
        driver.moveTo(col: 0, row: row)
        var col = 0
        while col < maxCols {
            let cell = cells[col]
            let width = Int(cell.width)
            if width <= 0 {
                col += 1
                continue
            }
            let attr = mapper.attribute(for: cell.attribute)
            driver.setAttribute(attr)
            driver.addCharacter(normalize(cell.char))
            col += width
        }
        while col < maxCols {
            driver.addCharacter(" ")
            col += 1
        }
    }

    private func normalize(_ value: String) -> Character {
        if value.isEmpty || value == "\0" {
            return " "
        }
        return value.first ?? " "
    }
}

private final class PaneAttributeMapper {
    private let driver: ConsoleDriver
    private var cache: [PaneAttribute: Attribute] = [:]

    init(driver: ConsoleDriver) {
        self.driver = driver
    }

    func attribute(for pane: PaneAttribute) -> Attribute {
        if let cached = cache[pane] {
            return cached
        }
        let fore = mapColor(pane.foreground, fallback: .gray)
        let back = mapColor(pane.background, fallback: .black)
        var flags: CellFlags = []
        let raw = pane.style
        if raw & 1 != 0 { flags.insert(.bold) }
        if raw & 2 != 0 { flags.insert(.underline) }
        if raw & 4 != 0 { flags.insert(.blink) }
        if raw & 8 != 0 { flags.insert(.invert) }
        if raw & 32 != 0 { flags.insert(.dim) }
        let attr = driver.makeAttribute(fore: fore, back: back, flags: flags)
        cache[pane] = attr
        return attr
    }

    private func mapColor(_ color: PaneColor, fallback: Color) -> Color {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            return fallback
        case .ansi(let code):
            return mapAnsi(code)
        case .trueColor(let r, let g, let b):
            return .rgb(Int(r), Int(g), Int(b))
        }
    }

    private func mapAnsi(_ code: UInt8) -> Color {
        switch code {
        case 0: return .black
        case 1: return .red
        case 2: return .green
        case 3: return .brown
        case 4: return .blue
        case 5: return .magenta
        case 6: return .cyan
        case 7: return .gray
        case 8: return .darkGray
        case 9: return .brightRed
        case 10: return .brightGreen
        case 11: return .brightYellow
        case 12: return .brightBlue
        case 13: return .brightMagenta
        case 14: return .brightCyan
        case 15: return .white
        default:
            let (r, g, b) = ansiToRgb(code)
            return .rgb(r, g, b)
        }
    }

    private func ansiToRgb(_ code: UInt8) -> (Int, Int, Int) {
        if code >= 232 {
            let level = Int(code) - 232
            let value = 8 + (level * 10)
            return (value, value, value)
        }
        let idx = Int(code) - 16
        if idx < 0 {
            return (0, 0, 0)
        }
        let r = idx / 36
        let g = (idx % 36) / 6
        let b = idx % 6
        return (colorStep(r), colorStep(g), colorStep(b))
    }

    private func colorStep(_ value: Int) -> Int {
        if value == 0 {
            return 0
        }
        return 55 + value * 40
    }
}

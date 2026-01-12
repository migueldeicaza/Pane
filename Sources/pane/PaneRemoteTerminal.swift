import Foundation
import SwiftTerm
import Logging

private final class PaneRemoteDelegate: TerminalDelegate {
    weak var owner: PaneRemoteTerminal?

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        owner?.handleSend(data)
    }
}

final class PaneRemoteTerminal {
    let terminal: Terminal
    private let delegateBridge: PaneRemoteDelegate
    private let logger = Logger(label: "pane.remote")
    private var renderer = PaneTerminalRenderer()

    init() {
        let delegateBridge = PaneRemoteDelegate()
        terminal = Terminal(delegate: delegateBridge, options: TerminalOptions.default)
        self.delegateBridge = delegateBridge
        delegateBridge.owner = self
    }

    func apply(snapshot: PaneTerminalSnapshot) {
        if terminal.cols != snapshot.cols || terminal.rows != snapshot.rows {
            terminal.resize(cols: snapshot.cols, rows: snapshot.rows)
        }
        renderer.reset()
        let payload = renderer.render(snapshot: snapshot)
        feed(payload)
    }

    func apply(delta: PaneTerminalDelta) {
        let payload = renderer.render(delta: delta)
        feed(payload)
    }

    func snapshotText() -> String {
        var lines: [String] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            let chars = line.getData().map { data -> Character in
                let ch = terminal.getCharacter(for: data)
                return ch == "\0" ? " " : ch
            }
            lines.append(String(chars))
        }
        return lines.joined(separator: "\n")
    }

    func handleSend(_ data: ArraySlice<UInt8>) {
        logger.debug("terminal produced output", metadata: ["bytes": "\(data.count)"])
    }

    private func feed(_ text: String) {
        let bytes = Array(text.utf8)
        terminal.feed(buffer: bytes[...])
    }
}

struct PaneTerminalRenderer {
    private var currentAttribute: PaneAttribute = PaneAttribute(SwiftTerm.Attribute.empty)

    mutating func reset() {
        currentAttribute = PaneAttribute(SwiftTerm.Attribute.empty)
    }

    mutating func render(snapshot: PaneTerminalSnapshot) -> String {
        var output = ""
        output += snapshot.isAlternate ? "\u{1b}[?1049h" : "\u{1b}[?1049l"
        output += PaneAnsi.clearScreen()
        for (rowIndex, line) in snapshot.lines.enumerated() {
            output += PaneAnsi.moveCursor(row: rowIndex + 1, col: 1)
            output += PaneAnsi.clearLine()
            output += renderLine(line)
        }
        output += PaneAnsi.moveCursor(row: snapshot.cursorY + 1, col: snapshot.cursorX + 1)
        return output
    }

    mutating func render(delta: PaneTerminalDelta) -> String {
        var output = ""
        for (offset, line) in delta.lines.enumerated() {
            let row = delta.startY + offset
            output += PaneAnsi.moveCursor(row: row + 1, col: 1)
            output += PaneAnsi.clearLine()
            output += renderLine(line)
        }
        output += PaneAnsi.moveCursor(row: delta.cursorY + 1, col: delta.cursorX + 1)
        return output
    }

    private mutating func renderLine(_ cells: [PaneCell]) -> String {
        var output = ""
        var col = 0
        currentAttribute = PaneAttribute(SwiftTerm.Attribute.empty)
        output += PaneAnsi.sgr(for: currentAttribute)

        while col < cells.count {
            let cell = cells[col]
            let width = Int(cell.width)
            if width <= 0 {
                col += 1
                continue
            }
            if cell.attribute != currentAttribute {
                output += PaneAnsi.sgr(for: cell.attribute)
                currentAttribute = cell.attribute
            }
            output += normalize(cell.char)
            col += width
        }
        return output
    }

    private func normalize(_ value: String) -> String {
        if value.isEmpty || value == "\0" {
            return " "
        }
        return value
    }
}

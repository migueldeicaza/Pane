import Foundation
import SwiftTerm
import Darwin
import Logging

final class PaneTerminalDelegate: TerminalDelegate {
    weak var session: PaneTerminalSession?

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        session?.sendToProcess(data)
    }
}

final class PaneTerminalSession: Terminal, LocalProcessDelegate {
    let id: String
    let name: String?
    let createdAt: Date

    private let sessionQueue: DispatchQueue
    private let delegateBridge: PaneTerminalDelegate
    private var process: LocalProcess!
    private var lastExitCode: Int32?
    private let logger: Logger
    private var subscribers: [UUID: PaneServerClient] = [:]

    init(id: String, name: String?, options: TerminalOptions = TerminalOptions.default) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.sessionQueue = DispatchQueue(label: "pane.session.\(id)")
        self.delegateBridge = PaneTerminalDelegate()
        self.logger = Logger(label: "pane.session.\(id)")
        super.init(delegate: delegateBridge, options: options)
        self.delegateBridge.session = self
        self.process = LocalProcess(delegate: self, dispatchQueue: sessionQueue)
    }

    func start(commandLine: [String]?) {
        let shell = commandLine?.first ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let args = commandLine?.dropFirst().map { $0 } ?? []
        logger.info("starting process", metadata: ["executable": "\(shell)", "args": "\(args)"])
        process.startProcess(executable: shell, args: args)
    }

    func terminate() {
        logger.info("terminating process")
        process.terminate()
    }

    var isRunning: Bool {
        process?.running ?? false
    }

    var processID: Int32? {
        let pid = process?.shellPid ?? 0
        return pid == 0 ? nil : pid
    }

    func sendToProcess(_ data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func sendInput(_ data: Data) {
        let bytes = [UInt8](data)
        sendToProcess(bytes[...])
    }

    func resizeTerminal(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else {
            return
        }
        resize(cols: cols, rows: rows)
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lastExitCode = exitCode
        let exitString = exitCode.map(String.init) ?? "nil"
        logger.info("process terminated", metadata: ["exitCode": "\(exitString)"])
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        feed(buffer: slice)
        sendDeltaIfNeeded()
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    func snapshot() -> String {
        sessionQueue.sync {
            var lines: [String] = []
            for row in 0..<rows {
                guard let line = getLine(row: row) else { continue }
                let rendered = renderLine(line)
                lines.append(rendered)
            }
            return lines.joined(separator: "\n")
        }
    }

    private func renderLine(_ line: BufferLine) -> String {
        let chars = line.getData().map { data -> Character in
            let ch = data.getCharacter()
            return ch == "\0" ? " " : ch
        }
        return trimTrailingSpaces(String(chars))
    }

    private func trimTrailingSpaces(_ value: String) -> String {
        var trimmed = value
        while trimmed.last == " " {
            trimmed.removeLast()
        }
        return trimmed
    }

    func addSubscriber(_ client: PaneServerClient) {
        sessionQueue.sync {
            subscribers[client.id] = client
        }
    }

    func removeSubscriber(id: UUID) {
        _ = sessionQueue.sync {
            subscribers.removeValue(forKey: id)
        }
    }

    func sendSnapshot(to client: PaneServerClient) {
        let snapshot = makeSnapshot()
        client.send(.snapshot(snapshot))
    }

    private func sendDeltaIfNeeded() {
        guard !subscribers.isEmpty else {
            clearUpdateRange()
            return
        }
        guard let range = getUpdateRange() else {
            return
        }
        let safeStart = max(0, range.startY)
        let safeEnd = min(rows - 1, range.endY)
        guard safeEnd >= safeStart else {
            clearUpdateRange()
            return
        }
        let delta = makeDelta(startY: safeStart, endY: safeEnd)
        clearUpdateRange()
        for client in subscribers.values {
            client.send(.delta(delta))
        }
    }

    private func makeSnapshot() -> PaneTerminalSnapshot {
        let cursor = getCursorLocation()
        let lines = (0..<rows).map { row in
            buildLine(row: row)
        }
        return PaneTerminalSnapshot(
            cols: cols,
            rows: rows,
            cursorX: cursor.x,
            cursorY: cursor.y,
            isAlternate: isCurrentBufferAlternate,
            lines: lines
        )
    }

    private func makeDelta(startY: Int, endY: Int) -> PaneTerminalDelta {
        let cursor = getCursorLocation()
        let lines = (startY...endY).map { row in
            buildLine(row: row)
        }
        return PaneTerminalDelta(
            startY: startY,
            endY: endY,
            cursorX: cursor.x,
            cursorY: cursor.y,
            lines: lines
        )
    }

    private func buildLine(row: Int) -> [PaneCell] {
        var cells: [PaneCell] = []
        cells.reserveCapacity(cols)
        for col in 0..<cols {
            guard let data = getCharData(col: col, row: row) else {
                continue
            }
            let character = String(getCharacter(for: data))
            let cell = PaneCell(
                char: character,
                width: data.width,
                attribute: PaneAttribute(data.attribute)
            )
            cells.append(cell)
        }
        if cells.count < cols {
            let filler = PaneCell(char: " ", width: 1, attribute: PaneAttribute(SwiftTerm.Attribute.empty))
            cells.append(contentsOf: repeatElement(filler, count: cols - cells.count))
        }
        return cells
    }
}

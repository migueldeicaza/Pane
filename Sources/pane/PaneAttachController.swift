import Foundation
import Logging
import ArgumentParser

final class PaneAttachController {
    private let client: PaneClient
    private let logger: Logger
    private let renderer: PaneConsoleRenderer
    private var connection: PaneFramedConnection?
    private var currentSessionID: String?
    private var sessionOrder: [String] = []
    private var commandMode = false
    private let stateQueue = DispatchQueue(label: "pane.attach.state")
    private let readQueue = DispatchQueue(label: "pane.attach.read")
    private let driver: ConsoleDriver

    init(client: PaneClient, logger: Logger, driver: ConsoleDriver) {
        self.client = client
        self.logger = logger
        self.driver = driver
        self.renderer = PaneConsoleRenderer(driver: driver)
        Application.onKeyEvent = { [weak self] event in
            self?.handleKey(event)
        }
        Application.onResize = { [weak self] in
            self?.handleResize()
        }
    }

    func start(initialRequest: PaneRequest, allowStart: Bool) throws {
        try attach(request: initialRequest, allowStart: allowStart)
    }

    func stopAndExit() -> Never {
        cleanup()
        exit(0)
    }

    private func cleanup() {
        stateQueue.sync {
            connection?.close()
            connection = nil
        }
        renderer.end()
        Application.onKeyEvent = nil
        Application.onResize = nil
    }

    private func handleKey(_ event: KeyEvent) {
        if commandMode {
            commandMode = false
            handleCommand(event)
            return
        }
        if isCommandTrigger(event) {
            commandMode = true
            return
        }
        if let data = encodeKeyEvent(event) {
            sendInput(data)
        }
    }

    private func handleCommand(_ event: KeyEvent) {
        guard let command = extractCommand(event) else {
            return
        }
        switch command {
        case "d":
            stopAndExit()
        case "c":
            createAndSwitch()
        case "n":
            switchRelative(offset: 1)
        case "p":
            switchRelative(offset: -1)
        default:
            break
        }
    }

    private func createAndSwitch() {
        do {
            let response = try client.send(PaneRequest(command: .createSession))
            guard response.ok, let session = response.session else {
                logger.error("create failed", metadata: ["message": "\(response.message ?? "unknown error")"])
                return
            }
            try attach(request: PaneRequest(command: .attachSession, sessionID: session.id), allowStart: true)
        } catch {
            logger.error("create failed", metadata: ["error": "\(error)"])
        }
    }

    private func switchRelative(offset: Int) {
        do {
            try refreshSessions()
            guard let current = currentSessionID, let index = sessionOrder.firstIndex(of: current) else {
                return
            }
            guard !sessionOrder.isEmpty else { return }
            let count = sessionOrder.count
            let nextIndex = (index + offset + count) % count
            let target = sessionOrder[nextIndex]
            if target == current {
                return
            }
            try attach(request: PaneRequest(command: .attachSession, sessionID: target), allowStart: true)
        } catch {
            logger.error("switch failed", metadata: ["error": "\(error)"])
        }
    }

    private func refreshSessions() throws {
        let response = try client.send(PaneRequest(command: .listSessions))
        guard response.ok, let sessions = response.sessions else {
            return
        }
        sessionOrder = sessions.map { $0.id }
    }

    private func attach(request: PaneRequest, allowStart: Bool) throws {
        let newConnection = try client.openConnection(allowStart: allowStart)
        let sizedRequest = applyingCurrentSize(to: request)
        try newConnection.send(.request(sizedRequest))

        guard let responseMessage = try newConnection.readMessage(),
              responseMessage.type == .response,
              let response = responseMessage.response else {
            throw ValidationError("invalid attach response")
        }
        guard response.ok else {
            throw ValidationError(response.message ?? "attach failed")
        }
        guard let session = response.session else {
            throw ValidationError("missing session in attach response")
        }

        guard let snapshotMessage = try newConnection.readMessage(),
              snapshotMessage.type == .snapshot,
              let snapshot = snapshotMessage.snapshot else {
            throw ValidationError("missing snapshot")
        }

        stateQueue.sync {
            connection?.close()
            connection = newConnection
            currentSessionID = session.id
        }

        renderer.render(snapshot: snapshot)
        logger.info("attached", metadata: ["session": "\(session.id)"])
        refreshSessionsIfNeeded(current: session.id)
        startReadLoop(connection: newConnection)
        sendResize()
    }

    private func refreshSessionsIfNeeded(current: String) {
        do {
            try refreshSessions()
            if sessionOrder.contains(current) == false {
                sessionOrder.append(current)
            }
        } catch {
            logger.warning("session list refresh failed", metadata: ["error": "\(error)"])
        }
    }

    private func startReadLoop(connection: PaneFramedConnection) {
        readQueue.async {
            while true {
                do {
                    guard let message = try connection.readMessage() else {
                        break
                    }
                    if message.type == .delta, let delta = message.delta {
                        self.renderer.render(delta: delta)
                    }
                } catch {
                    break
                }
            }
            if self.isCurrentConnection(connection) {
                self.stopAndExit()
            }
        }
    }

    private func isCurrentConnection(_ candidate: PaneFramedConnection) -> Bool {
        stateQueue.sync {
            connection === candidate
        }
    }

    private func sendInput(_ data: Data) {
        guard let connection = stateQueue.sync(execute: { self.connection }) else {
            return
        }
        do {
            try connection.send(.input(PaneInputMessage(data: data)))
        } catch {
            logger.error("send input failed", metadata: ["error": "\(error)"])
        }
    }

    private func handleResize() {
        sendResize()
    }

    private func sendResize() {
        guard let connection = stateQueue.sync(execute: { self.connection }) else {
            return
        }
        let size = normalizedSize()
        do {
            try connection.send(.resize(PaneResizeMessage(cols: size.cols, rows: size.rows)))
        } catch {
            logger.error("send resize failed", metadata: ["error": "\(error)"])
        }
    }

    private func applyingCurrentSize(to request: PaneRequest) -> PaneRequest {
        let size = normalizedSize()
        return PaneRequest(
            command: request.command,
            sessionID: request.sessionID,
            name: request.name,
            commandLine: request.commandLine,
            cols: size.cols,
            rows: size.rows
        )
    }

    private func normalizedSize() -> (cols: Int, rows: Int) {
        let cols = driver.size.width > 0 ? driver.size.width : 80
        let rows = driver.size.height > 0 ? driver.size.height : 24
        return (cols, rows)
    }

    private func isCommandTrigger(_ event: KeyEvent) -> Bool {
        if case .controlB = event.key { return true }
        if case .letter(let ch) = event.key, event.isControl, ch == "b" { return true }
        return false
    }

    private func extractCommand(_ event: KeyEvent) -> Character? {
        switch event.key {
        case .letter(let ch):
            if ch.isUppercase {
                return Character(ch.lowercased())
            }
            return ch
        case .controlD:
            return "d"
        case .controlC:
            return "c"
        case .controlN:
            return "n"
        case .controlP:
            return "p"
        default:
            return nil
        }
    }

    private func encodeKeyEvent(_ event: KeyEvent) -> Data? {
        switch event.key {
        case .letter(let ch):
            if event.isControl {
                return controlCharacter(for: ch)
            }
            let text = String(ch)
            if event.isAlt {
                var data = Data([0x1b])
                data.append(contentsOf: text.utf8)
                return data
            }
            return Data(text.utf8)
        case .controlSpace: return Data([0])
        case .controlA: return Data([1])
        case .controlB: return Data([2])
        case .controlC: return Data([3])
        case .controlD: return Data([4])
        case .controlE: return Data([5])
        case .controlF: return Data([6])
        case .controlG: return Data([7])
        case .controlH: return Data([8])
        case .controlI: return Data([9])
        case .controlJ: return Data([10])
        case .controlK: return Data([11])
        case .controlL: return Data([12])
        case .controlM: return Data([13])
        case .controlN: return Data([14])
        case .controlO: return Data([15])
        case .controlP: return Data([16])
        case .controlQ: return Data([17])
        case .controlR: return Data([18])
        case .controlS: return Data([19])
        case .controlT: return Data([20])
        case .controlU: return Data([21])
        case .controlV: return Data([22])
        case .controlW: return Data([23])
        case .controlX: return Data([24])
        case .controlY: return Data([25])
        case .controlZ: return Data([26])
        case .esc: return Data([0x1b])
        case .delete, .deleteChar: return Data([0x7f])
        case .backspace: return Data([0x08])
        case .tab: return Data([0x09])
        case .cursorUp: return Data("\u{1b}[A".utf8)
        case .cursorDown: return Data("\u{1b}[B".utf8)
        case .cursorRight: return Data("\u{1b}[C".utf8)
        case .cursorLeft: return Data("\u{1b}[D".utf8)
        case .home: return Data("\u{1b}[H".utf8)
        case .end: return Data("\u{1b}[F".utf8)
        case .pageUp: return Data("\u{1b}[5~".utf8)
        case .pageDown: return Data("\u{1b}[6~".utf8)
        case .insertChar: return Data("\u{1b}[2~".utf8)
        case .f1: return Data("\u{1b}OP".utf8)
        case .f2: return Data("\u{1b}OQ".utf8)
        case .f3: return Data("\u{1b}OR".utf8)
        case .f4: return Data("\u{1b}OS".utf8)
        case .f5: return Data("\u{1b}[15~".utf8)
        case .f6: return Data("\u{1b}[17~".utf8)
        case .f7: return Data("\u{1b}[18~".utf8)
        case .f8: return Data("\u{1b}[19~".utf8)
        case .f9: return Data("\u{1b}[20~".utf8)
        case .f10: return Data("\u{1b}[21~".utf8)
        case .Unknown, .fs, .gs, .rs, .us, .backtab, .shiftCursorLeft, .shiftCursorRight:
            return nil
        }
    }

    private func controlCharacter(for ch: Character) -> Data? {
        guard let scalar = ch.unicodeScalars.first else { return nil }
        let value = scalar.value
        if value >= 0x60 && value <= 0x7a {
            let code = UInt8(value - 0x60)
            return Data([code])
        }
        if value >= 0x40 && value <= 0x5a {
            let code = UInt8(value - 0x40)
            return Data([code])
        }
        return nil
    }
}

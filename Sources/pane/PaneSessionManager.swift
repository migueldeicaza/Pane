import Foundation
import Logging

final class PaneSessionManager {
    private var sessions: [String: PaneTerminalSession] = [:]
    private var nextSessionID: UInt64 = 1
    private let queue = DispatchQueue(label: "pane.sessions")
    private let logger = Logger(label: "pane.sessions")

    func handle(request: PaneRequest) -> PaneResponse {
        queue.sync {
            switch request.command {
            case .createSession:
                return createSession(name: request.name, commandLine: request.commandLine)
            case .listSessions:
                return listSessions()
            case .destroySession:
                guard let sessionID = request.sessionID, !sessionID.isEmpty else {
                    return PaneResponse(ok: false, message: "session id required")
                }
                return destroySession(id: sessionID)
            case .attachSession:
                guard let sessionID = request.sessionID, !sessionID.isEmpty else {
                    return PaneResponse(ok: false, message: "session id required")
                }
                return attachSession(id: sessionID)
            case .ping:
                return PaneResponse(ok: true, message: "pong")
            }
        }
    }

    func session(for request: PaneRequest) -> PaneTerminalSession? {
        guard let sessionID = request.sessionID, !sessionID.isEmpty else {
            return nil
        }
        return queue.sync {
            sessions[sessionID]
        }
    }

    private func createSession(name: String?, commandLine: [String]?) -> PaneResponse {
        let id = String(nextSessionID)
        nextSessionID += 1
        let session = PaneTerminalSession(id: id, name: name)
        session.start(commandLine: commandLine)
        sessions[id] = session
        let sessionName = name ?? "-"
        logger.info("session created", metadata: ["session": "\(id)", "name": "\(sessionName)"])
        return PaneResponse(ok: true, session: session.info())
    }

    private func listSessions() -> PaneResponse {
        let infos = sessions.values
            .map { $0.info() }
            .sorted { $0.createdAt < $1.createdAt }
        return PaneResponse(ok: true, sessions: infos)
    }

    private func destroySession(id: String) -> PaneResponse {
        guard let session = sessions[id] else {
            logger.warning("session not found", metadata: ["session": "\(id)"])
            return PaneResponse(ok: false, message: "session not found")
        }
        sessions.removeValue(forKey: session.id)
        session.terminate()
        logger.info("session destroyed", metadata: ["session": "\(session.id)"])
        return PaneResponse(ok: true, message: "destroyed \(session.id)")
    }

    private func attachSession(id: String) -> PaneResponse {
        guard let session = sessions[id] else {
            logger.warning("session not found", metadata: ["session": "\(id)"])
            return PaneResponse(ok: false, message: "session not found")
        }
        logger.info("session attached", metadata: ["session": "\(session.id)"])
        return PaneResponse(ok: true, session: session.info())
    }
}

private extension PaneTerminalSession {
    func info() -> PaneSessionInfo {
        PaneSessionInfo(id: id, name: name, createdAt: createdAt, isRunning: isRunning, processID: processID)
    }
}

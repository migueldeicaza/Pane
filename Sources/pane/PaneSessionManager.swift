import Foundation
import Logging

final class PaneSessionManager {
    private var sessions: [String: PaneTerminalSession] = [:]
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
                guard let target = resolveTarget(id: request.sessionID, pid: request.sessionPID) else {
                    return PaneResponse(ok: false, message: "session id or pid required")
                }
                return destroySession(target: target)
            case .attachSession:
                guard let target = resolveTarget(id: request.sessionID, pid: request.sessionPID) else {
                    return PaneResponse(ok: false, message: "session id or pid required")
                }
                return attachSession(target: target)
            case .ping:
                return PaneResponse(ok: true, message: "pong")
            }
        }
    }

    func session(for request: PaneRequest) -> PaneTerminalSession? {
        guard let target = resolveTarget(id: request.sessionID, pid: request.sessionPID) else {
            return nil
        }
        return queue.sync {
            session(for: target)
        }
    }

    private func createSession(name: String?, commandLine: [String]?) -> PaneResponse {
        let id = UUID().uuidString
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

    private func destroySession(target: SessionTarget) -> PaneResponse {
        guard let session = session(for: target) else {
            logger.warning("session not found", metadata: target.metadata)
            return PaneResponse(ok: false, message: "session not found")
        }
        sessions.removeValue(forKey: session.id)
        session.terminate()
        logger.info("session destroyed", metadata: ["session": "\(session.id)"])
        return PaneResponse(ok: true, message: "destroyed \(session.id)")
    }

    private func attachSession(target: SessionTarget) -> PaneResponse {
        guard let session = session(for: target) else {
            logger.warning("session not found", metadata: target.metadata)
            return PaneResponse(ok: false, message: "session not found")
        }
        logger.info("session attached", metadata: ["session": "\(session.id)"])
        return PaneResponse(ok: true, session: session.info())
    }

    private func resolveTarget(id: String?, pid: Int32?) -> SessionTarget? {
        if let id, !id.isEmpty {
            return .id(id)
        }
        if let pid, pid > 0 {
            return .pid(pid)
        }
        return nil
    }

    private func session(for target: SessionTarget) -> PaneTerminalSession? {
        switch target {
        case .id(let id):
            return sessions[id]
        case .pid(let pid):
            return sessions.values.first { $0.processID == pid }
        }
    }
}

private extension PaneTerminalSession {
    func info() -> PaneSessionInfo {
        PaneSessionInfo(id: id, name: name, createdAt: createdAt, isRunning: isRunning, processID: processID)
    }
}

private enum SessionTarget {
    case id(String)
    case pid(Int32)

    var metadata: Logger.Metadata {
        switch self {
        case .id(let id):
            return ["session": "\(id)"]
        case .pid(let pid):
            return ["pid": "\(pid)"]
        }
    }
}

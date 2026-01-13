import Foundation
import Darwin
import Logging

enum PaneSocketError: Error, CustomStringConvertible {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case connectFailed(Int32)
    case pathTooLong

    var description: String {
        switch self {
        case .socketCreationFailed(let code):
            return "socket creation failed (errno \(code))"
        case .bindFailed(let code):
            return "socket bind failed (errno \(code))"
        case .listenFailed(let code):
            return "socket listen failed (errno \(code))"
        case .connectFailed(let code):
            return "socket connect failed (errno \(code))"
        case .pathTooLong:
            return "socket path too long"
        }
    }
}

final class PaneServer {
    private let socketPath: String
    private let sessionManager = PaneSessionManager()
    private let acceptQueue = DispatchQueue(label: "pane.server.accept")
    private var listenerFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let logger = Logger(label: "pane.server")
    private let startedAt = Date()

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        try setupSocket()
        try PanePaths.writePidFile(pid: getpid())
        logger.info("server listening", metadata: ["socket": "\(socketPath)"])
        let source = DispatchSource.makeReadSource(fileDescriptor: listenerFd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [listenerFd] in
            close(listenerFd)
        }
        source.resume()
        acceptSource = source
    }

    private func setupSocket() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PaneSocketError.socketCreationFailed(errno)
        }

        listenerFd = fd
        var addr = sockaddr_un()
        #if os(macOS)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathData = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathData.count <= maxLen else {
            throw PaneSocketError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            pathData.withUnsafeBytes { pathBuffer in
                buffer.copyBytes(from: pathBuffer)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw PaneSocketError.bindFailed(errno)
        }

        _ = chmod(socketPath, mode_t(0o600))

        guard listen(fd, 16) == 0 else {
            throw PaneSocketError.listenFailed(errno)
        }
    }

    private func acceptConnection() {
        let fd = accept(listenerFd, nil, nil)
        guard fd >= 0 else {
            logger.error("failed to accept connection", metadata: ["errno": "\(errno)"])
            return
        }
        handleConnection(fd)
    }

    private func handleConnection(_ fd: Int32) {
        DispatchQueue.global(qos: .utility).async {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let connection = PaneFramedConnection(handle: handle)
            do {
                guard let message = try connection.readMessage(), message.type == .request, let request = message.request else {
                    self.logger.error("invalid request message")
                    let response = PaneResponse(ok: false, message: "invalid request")
                    try connection.send(.response(self.decorate(response)))
                    connection.close()
                    return
                }

                let sessionID = request.sessionID ?? "-"
                self.logger.info("request received", metadata: ["command": "\(request.command.rawValue)", "session": "\(sessionID)"])
                let response = self.decorate(self.sessionManager.handle(request: request))

                if request.command == .attachSession, response.ok, let session = self.sessionManager.session(for: request) {
                    let client = PaneServerClient(connection: connection)
                    client.onClose = { id in
                        session.removeSubscriber(id: id)
                    }
                    session.addSubscriber(client)
                    if let cols = request.cols, let rows = request.rows {
                        session.resizeTerminal(cols: cols, rows: rows)
                    }
                    client.send(.response(response))
                    session.sendSnapshot(to: client)
                    client.startReceiveLoop { message in
                        if message.type == .input, let input = message.input {
                            session.sendInput(input.data)
                        } else if message.type == .resize, let resize = message.resize {
                            session.resizeTerminal(cols: resize.cols, rows: resize.rows)
                        }
                    }
                    return
                }

                try connection.send(.response(response))
                connection.close()
            } catch {
                self.logger.error("connection handling failed", metadata: ["error": "\(error)"])
                connection.close()
            }
        }
    }

    private func decorate(_ response: PaneResponse) -> PaneResponse {
        var updated = response
        updated.server = PaneServerInfo(pid: getpid(), startedAt: startedAt, socketPath: socketPath)
        return updated
    }
}

final class PaneServerClient {
    let id = UUID()
    private let connection: PaneFramedConnection
    private let queue = DispatchQueue(label: "pane.server.client")
    private let readQueue = DispatchQueue(label: "pane.server.client.read")
    private var isClosed = false
    var onClose: ((UUID) -> Void)?

    init(connection: PaneFramedConnection) {
        self.connection = connection
    }

    func send(_ message: PaneWireMessage) {
        queue.async {
            guard !self.isClosed else { return }
            do {
                // Use binary format for high-frequency terminal data
                switch message.type {
                case .snapshot, .delta:
                    try self.connection.sendBinary(message)
                default:
                    try self.connection.send(message)
                }
            } catch {
                self.close()
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.close()
        onClose?(id)
    }

    func startReceiveLoop(handler: @escaping (PaneWireMessage) -> Void) {
        readQueue.async {
            while !self.isClosed {
                do {
                    guard let message = try self.connection.readMessage() else {
                        break
                    }
                    handler(message)
                } catch {
                    break
                }
            }
            self.close()
        }
    }
}

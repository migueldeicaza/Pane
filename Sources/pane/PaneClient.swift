import Foundation
import Darwin
import Logging

final class PaneClient {
    private let socketPath: String
    private let logToFile: Bool
    private let logger = Logger(label: "pane.client")

    init(socketPath: String, logToFile: Bool) {
        self.socketPath = socketPath
        self.logToFile = logToFile
    }

    func send(_ request: PaneRequest, allowStart: Bool = true) throws -> PaneResponse {
        logger.debug("sending request", metadata: ["command": "\(request.command.rawValue)"])
        let connection = try openConnection(allowStart: allowStart)
        defer { connection.close() }
        try connection.send(.request(request))
        guard let message = try connection.readMessage(), message.type == .response, let response = message.response else {
            logger.error("invalid response")
            return PaneResponse(ok: false, message: "invalid response")
        }
        return response
    }

    func openConnection(allowStart: Bool) throws -> PaneFramedConnection {
        let fd = try connect(allowStart: allowStart)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return PaneFramedConnection(handle: handle)
    }

    private func connect(allowStart: Bool) throws -> Int32 {
        do {
            return try connectOnce()
        } catch {
            guard allowStart else { throw error }
            guard case let .connectFailed(code) = error as? PaneSocketError,
                  code == ENOENT || code == ECONNREFUSED else {
                throw error
            }
            if code == ECONNREFUSED {
                try? FileManager.default.removeItem(atPath: socketPath)
            }
            logger.info("starting server process")
            try startServerProcess()
            return try connectWithRetry()
        }
    }

    private func connectOnce() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PaneSocketError.socketCreationFailed(errno)
        }

        var addr = sockaddr_un()
        #if os(macOS)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathData = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathData.count <= maxLen else {
            close(fd)
            throw PaneSocketError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            pathData.withUnsafeBytes { pathBuffer in
                buffer.copyBytes(from: pathBuffer)
            }
        }

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let code = errno
            close(fd)
            throw PaneSocketError.connectFailed(code)
        }
        return fd
    }

    private func connectWithRetry() throws -> Int32 {
        var lastError: Error = PaneSocketError.connectFailed(ECONNREFUSED)
        for _ in 0..<25 {
            do {
                return try connectOnce()
            } catch {
                lastError = error
                logger.debug("connect retry failed", metadata: ["error": "\(error)"])
                usleep(100_000)
            }
        }
        throw lastError
    }

    private func startServerProcess() throws {
        let execPath = resolveExecutablePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = logToFile ? ["--server", "--log"] : ["--server"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func resolveExecutablePath() -> String {
        let arg0 = CommandLine.arguments.first ?? "pane"
        if arg0.hasPrefix("/") {
            return arg0
        }
        if arg0.contains("/") {
            let cwd = FileManager.default.currentDirectoryPath
            return URL(fileURLWithPath: cwd).appendingPathComponent(arg0).path
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(arg0).path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd).appendingPathComponent(arg0).path
    }
}

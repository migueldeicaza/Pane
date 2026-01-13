import Foundation
import ArgumentParser
import Logging

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Log to a file under the pane runtime directory.")
    var log = false

    @Flag(name: .customLong("no-auto-start"), help: "Don't auto-start the server for client commands.")
    var noAutoStart = false
}

struct PaneContext {
    let logger: Logger
    let socketPath: String
    let logToFile: Bool

    init(options: GlobalOptions) throws {
        let logPath = try PaneLogging.configure(logToFile: options.log)
        let logger = Logger(label: "pane")
        if let logPath, options.log {
            logger.info("logging enabled", metadata: ["path": "\(logPath)"])
        }
        self.logger = logger
        self.socketPath = try PanePaths.socketPath()
        self.logToFile = options.log
    }

    func makeClient() -> PaneClient {
        PaneClient(socketPath: socketPath, logToFile: logToFile)
    }
}

func runServer(socketPath: String, logger: Logger) throws -> Never {
    let server = PaneServer(socketPath: socketPath)
    try server.start()
    logger.info("server running")
    dispatchMain()
}

func makeConsoleDriver() -> ConsoleDriver {
#if os(Windows)
    return WindowsDriver()
#else
    return UnixDriver()
#endif
}

func attachAndStream(client: PaneClient, request: PaneRequest, allowStart: Bool, logger: Logger) throws {
    let driver = makeConsoleDriver()
    let controller = PaneAttachController(client: client, logger: logger, driver: driver)
    try controller.start(initialRequest: request, allowStart: allowStart)
    RunLoop.main.run()
}

struct Pane: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "Minimal terminal multiplexer server/client.",
        subcommands: [Server.self, Status.self, ListServers.self, Create.self, List.self, Attach.self, Destroy.self]
    )

    @Flag(name: .customLong("server"), help: .hidden)
    var server = false

    @OptionGroup
    var global: GlobalOptions

    mutating func run() throws {
        let context = try PaneContext(options: global)
        if server {
            try runServer(socketPath: context.socketPath, logger: context.logger)
        }

        let client = context.makeClient()
        let createResponse = try client.send(PaneRequest(command: .createSession))
        guard createResponse.ok, let session = createResponse.session else {
            context.logger.error("create session failed", metadata: ["message": "\(createResponse.message ?? "unknown error")"])
            throw ValidationError(createResponse.message ?? "create session failed")
        }
        print("Created session \(session.id)")
        try attachAndStream(
            client: client,
            request: PaneRequest(command: .attachSession, sessionID: session.id),
            allowStart: true,
            logger: context.logger
        )
    }
}

struct Server: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Run the pane server.")

    @OptionGroup
    var global: GlobalOptions

    mutating func run() throws {
        let context = try PaneContext(options: global)
        try runServer(socketPath: context.socketPath, logger: context.logger)
    }
}

struct Status: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Check if a pane server is running.")

    @OptionGroup
    var global: GlobalOptions

    mutating func run() throws {
        let context = try PaneContext(options: global)
        let logger = context.logger
        let pidPath = try PanePaths.pidFilePath()
        let socketPath = context.socketPath
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: pidPath) else {
            print("no server (pid file missing)")
            return
        }
        let pid = try PanePaths.readPidFile()
        let alive = PaneProcessChecker.isAlive(pid: pid)
        let socketExists = fileManager.fileExists(atPath: socketPath)
        if alive {
            print("server pid: \(pid) (alive) socket: \(socketExists ? "present" : "missing")")
            let client = context.makeClient()
            if let response = try? client.send(PaneRequest(command: .ping), allowStart: false), response.ok {
                if let server = response.server {
                    let formatter = ISO8601DateFormatter()
                    print("server started: \(formatter.string(from: server.startedAt))")
                }
            } else {
                logger.warning("ping failed")
            }
        } else {
            print("server pid: \(pid) (dead) socket: \(socketExists ? "present" : "missing")")
        }
    }
}

struct ListServers: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "List available pane servers.")

    @OptionGroup
    var global: GlobalOptions

    mutating func run() throws {
        _ = try PaneContext(options: global)
        let runtimeDir = try PanePaths.runtimeDirectory()
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: runtimeDir, includingPropertiesForKeys: nil)
        let sockets = contents.filter { url in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType else {
                return false
            }
            return type == .typeSocket
        }
        if sockets.isEmpty {
            print("no servers found")
            return
        }
        let formatter = ISO8601DateFormatter()
        for socket in sockets.sorted(by: { $0.path < $1.path }) {
            let client = PaneClient(socketPath: socket.path, logToFile: global.log)
            if let response = try? client.send(PaneRequest(command: .ping), allowStart: false), response.ok, let server = response.server {
                let started = formatter.string(from: server.startedAt)
                print("\(socket.lastPathComponent)\tpid=\(server.pid)\tstarted=\(started)")
            } else {
                print("\(socket.lastPathComponent)\t(dead)")
            }
        }
    }
}

struct Create: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Create a new session.")

    @OptionGroup
    var global: GlobalOptions

    @Argument(help: "Optional session name.")
    var name: String?

    @Argument(parsing: .remaining, help: "Command to run in the session.")
    var command: [String] = []

    mutating func run() throws {
        let context = try PaneContext(options: global)
        let client = context.makeClient()
        let response = try client.send(PaneRequest(
            command: .createSession,
            name: name,
            commandLine: command.isEmpty ? nil : command
        ))
        guard response.ok, let session = response.session else {
            context.logger.error("create session failed", metadata: ["message": "\(response.message ?? "unknown error")"])
            throw ValidationError(response.message ?? "create session failed")
        }
        print(session.id)
    }
}

struct List: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "List sessions.")

    @OptionGroup
    var global: GlobalOptions

    mutating func run() throws {
        let context = try PaneContext(options: global)
        let client = context.makeClient()
        let response: PaneResponse
        do {
            response = try client.send(PaneRequest(command: .listSessions), allowStart: false)
        } catch let error as PaneSocketError {
            if case .connectFailed(let code) = error, code == ECONNREFUSED || code == ENOENT {
                print("No server running")
                return
            }
            throw error
        }
        guard response.ok else {
            context.logger.error("list sessions failed", metadata: ["message": "\(response.message ?? "unknown error")"])
            throw ValidationError(response.message ?? "list sessions failed")
        }
        if let server = response.server {
            print("server pid: \(server.pid)")
        }
        let formatter = ISO8601DateFormatter()
        for session in response.sessions ?? [] {
            let createdAt = formatter.string(from: session.createdAt)
            let name = session.name ?? "-"
            let state = session.isRunning ? "running" : "stopped"
            let pid = session.processID.map(String.init) ?? "-"
            print("\(session.id)\t\(pid)\t\(name)\t\(state)\t\(createdAt)")
        }
    }
}

struct Attach: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Attach to a session (stream updates).")

    @OptionGroup
    var global: GlobalOptions

    @Argument(help: "Session id (optional when only one session is running).")
    var sessionID: String?

    mutating func run() throws {
        let context = try PaneContext(options: global)
        let client = context.makeClient()
        let resolvedSessionID: String
        if let sessionID {
            resolvedSessionID = sessionID
        } else {
            let response = try client.send(PaneRequest(command: .listSessions), allowStart: !global.noAutoStart)
            guard response.ok else {
                context.logger.error("list sessions failed", metadata: ["message": "\(response.message ?? "unknown error")"])
                throw ValidationError(response.message ?? "list sessions failed")
            }
            let runningSessions = (response.sessions ?? []).filter { $0.isRunning }
            if runningSessions.count == 1, let session = runningSessions.first {
                resolvedSessionID = session.id
            } else if runningSessions.isEmpty {
                throw ValidationError("no running sessions (specify session id)")
            } else {
                throw ValidationError("multiple running sessions (specify session id)")
            }
        }
        try attachAndStream(
            client: client,
            request: PaneRequest(command: .attachSession, sessionID: resolvedSessionID),
            allowStart: !global.noAutoStart,
            logger: context.logger
        )
    }
}

struct Destroy: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Destroy a session.")

    @OptionGroup
    var global: GlobalOptions

    @Argument(help: "Session id.")
    var sessionID: String

    mutating func run() throws {
        let context = try PaneContext(options: global)
        let client = context.makeClient()
        let response: PaneResponse
        do {
            response = try client.send(PaneRequest(command: .destroySession, sessionID: sessionID), allowStart: false)
        } catch let error as PaneSocketError {
            if case .connectFailed(let code) = error, code == ECONNREFUSED || code == ENOENT {
                throw ValidationError("No server running")
            }
            throw error
        }
        guard response.ok else {
            context.logger.error("destroy failed", metadata: ["message": "\(response.message ?? "unknown error")"])
            throw ValidationError(response.message ?? "destroy failed")
        }
        if let message = response.message {
            print(message)
        }
    }
}

Pane.main()

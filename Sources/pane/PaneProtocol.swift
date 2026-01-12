import Foundation

enum PaneCommand: String, Codable {
    case createSession
    case listSessions
    case destroySession
    case attachSession
    case ping
}

enum PaneMessageType: String, Codable {
    case request
    case response
    case snapshot
    case delta
    case input
    case resize
}

struct PaneRequest: Codable {
    var command: PaneCommand
    var sessionID: String?
    var sessionPID: Int32?
    var name: String?
    var commandLine: [String]?
    var cols: Int?
    var rows: Int?

    init(command: PaneCommand, sessionID: String? = nil, sessionPID: Int32? = nil, name: String? = nil, commandLine: [String]? = nil, cols: Int? = nil, rows: Int? = nil) {
        self.command = command
        self.sessionID = sessionID
        self.sessionPID = sessionPID
        self.name = name
        self.commandLine = commandLine
        self.cols = cols
        self.rows = rows
    }
}

struct PaneSessionInfo: Codable {
    let id: String
    let name: String?
    let createdAt: Date
    let isRunning: Bool
    let processID: Int32?
}

struct PaneServerInfo: Codable {
    let pid: Int32
    let startedAt: Date
    let socketPath: String
}

struct PaneResponse: Codable {
    var ok: Bool
    var message: String?
    var sessions: [PaneSessionInfo]?
    var session: PaneSessionInfo?
    var server: PaneServerInfo?
}

struct PaneWireMessage: Codable {
    var type: PaneMessageType
    var request: PaneRequest?
    var response: PaneResponse?
    var snapshot: PaneTerminalSnapshot?
    var delta: PaneTerminalDelta?
    var input: PaneInputMessage?
    var resize: PaneResizeMessage?

    static func request(_ request: PaneRequest) -> PaneWireMessage {
        PaneWireMessage(type: .request, request: request, response: nil, snapshot: nil, delta: nil, input: nil, resize: nil)
    }

    static func response(_ response: PaneResponse) -> PaneWireMessage {
        PaneWireMessage(type: .response, request: nil, response: response, snapshot: nil, delta: nil, input: nil, resize: nil)
    }

    static func snapshot(_ snapshot: PaneTerminalSnapshot) -> PaneWireMessage {
        PaneWireMessage(type: .snapshot, request: nil, response: nil, snapshot: snapshot, delta: nil, input: nil, resize: nil)
    }

    static func delta(_ delta: PaneTerminalDelta) -> PaneWireMessage {
        PaneWireMessage(type: .delta, request: nil, response: nil, snapshot: nil, delta: delta, input: nil, resize: nil)
    }

    static func input(_ input: PaneInputMessage) -> PaneWireMessage {
        PaneWireMessage(type: .input, request: nil, response: nil, snapshot: nil, delta: nil, input: input, resize: nil)
    }

    static func resize(_ resize: PaneResizeMessage) -> PaneWireMessage {
        PaneWireMessage(type: .resize, request: nil, response: nil, snapshot: nil, delta: nil, input: nil, resize: resize)
    }
}

struct PaneTerminalSnapshot: Codable {
    var cols: Int
    var rows: Int
    var cursorX: Int
    var cursorY: Int
    var isAlternate: Bool
    var lines: [[PaneCell]]
}

struct PaneTerminalDelta: Codable {
    var startY: Int
    var endY: Int
    var cursorX: Int
    var cursorY: Int
    var lines: [[PaneCell]]
}

struct PaneInputMessage: Codable {
    var data: Data
}

struct PaneResizeMessage: Codable {
    var cols: Int
    var rows: Int
}

struct PaneCell: Codable, Equatable {
    var char: String
    var width: Int8
    var attribute: PaneAttribute
}

struct PaneAttribute: Codable, Equatable, Hashable {
    var foreground: PaneColor
    var background: PaneColor
    var style: UInt8
    var underlineColor: PaneColor?
}

enum PaneColor: Codable, Equatable, Hashable {
    case ansi(UInt8)
    case trueColor(UInt8, UInt8, UInt8)
    case defaultColor
    case defaultInvertedColor
}

extension JSONEncoder {
    static func paneEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static func paneDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

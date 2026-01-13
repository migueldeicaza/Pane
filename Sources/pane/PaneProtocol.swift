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
    var name: String?
    var commandLine: [String]?
    var cols: Int?
    var rows: Int?

    init(command: PaneCommand, sessionID: String? = nil, name: String? = nil, commandLine: [String]? = nil, cols: Int? = nil, rows: Int? = nil) {
        self.command = command
        self.sessionID = sessionID
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

// MARK: - Binary Encoding

enum PaneBinaryError: Error {
    case unexpectedEnd
    case invalidTag
    case invalidUTF8
}

struct PaneBinaryWriter {
    var data = Data()

    mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func writeInt8(_ value: Int8) {
        data.append(UInt8(bitPattern: value))
    }

    mutating func writeUInt16(_ value: UInt16) {
        var be = value.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &be) { Array($0) })
    }

    mutating func writeUInt32(_ value: UInt32) {
        var be = value.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &be) { Array($0) })
    }

    mutating func writeData(_ value: Data) {
        writeUInt32(UInt32(value.count))
        data.append(value)
    }

    mutating func writeString(_ value: String) {
        let utf8 = Data(value.utf8)
        writeUInt8(UInt8(truncatingIfNeeded: utf8.count))
        data.append(utf8)
    }
}

struct PaneBinaryReader {
    let data: Data
    var offset: Int = 0

    var remaining: Int { data.count - offset }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw PaneBinaryError.unexpectedEnd }
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }

    mutating func readInt8() throws -> Int8 {
        Int8(bitPattern: try readUInt8())
    }

    mutating func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw PaneBinaryError.unexpectedEnd }
        let b0 = data[data.startIndex + offset]
        let b1 = data[data.startIndex + offset + 1]
        offset += 2
        return (UInt16(b0) << 8) | UInt16(b1)
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw PaneBinaryError.unexpectedEnd }
        let b0 = data[data.startIndex + offset]
        let b1 = data[data.startIndex + offset + 1]
        let b2 = data[data.startIndex + offset + 2]
        let b3 = data[data.startIndex + offset + 3]
        offset += 4
        return (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
    }

    mutating func readData() throws -> Data {
        let count = Int(try readUInt32())
        guard offset + count <= data.count else { throw PaneBinaryError.unexpectedEnd }
        let start = data.startIndex + offset
        let value = Data(data[start..<start+count])
        offset += count
        return value
    }

    mutating func readString() throws -> String {
        let count = Int(try readUInt8())
        guard offset + count <= data.count else { throw PaneBinaryError.unexpectedEnd }
        let start = data.startIndex + offset
        let bytes = Data(data[start..<start+count])
        offset += count
        guard let str = String(data: bytes, encoding: .utf8) else {
            throw PaneBinaryError.invalidUTF8
        }
        return str
    }
}

protocol PaneBinaryCodable {
    func write(to writer: inout PaneBinaryWriter)
    init(from reader: inout PaneBinaryReader) throws
}

extension PaneColor: PaneBinaryCodable {
    func write(to writer: inout PaneBinaryWriter) {
        switch self {
        case .defaultColor:
            writer.writeUInt8(0)
        case .defaultInvertedColor:
            writer.writeUInt8(1)
        case .ansi(let index):
            writer.writeUInt8(2)
            writer.writeUInt8(index)
        case .trueColor(let r, let g, let b):
            writer.writeUInt8(3)
            writer.writeUInt8(r)
            writer.writeUInt8(g)
            writer.writeUInt8(b)
        }
    }

    init(from reader: inout PaneBinaryReader) throws {
        let tag = try reader.readUInt8()
        switch tag {
        case 0: self = .defaultColor
        case 1: self = .defaultInvertedColor
        case 2: self = .ansi(try reader.readUInt8())
        case 3: self = .trueColor(try reader.readUInt8(), try reader.readUInt8(), try reader.readUInt8())
        default: throw PaneBinaryError.invalidTag
        }
    }
}

extension PaneAttribute: PaneBinaryCodable {
    func write(to writer: inout PaneBinaryWriter) {
        foreground.write(to: &writer)
        background.write(to: &writer)
        writer.writeUInt8(style)
        if let underline = underlineColor {
            writer.writeUInt8(1)
            underline.write(to: &writer)
        } else {
            writer.writeUInt8(0)
        }
    }

    init(from reader: inout PaneBinaryReader) throws {
        foreground = try PaneColor(from: &reader)
        background = try PaneColor(from: &reader)
        style = try reader.readUInt8()
        let hasUnderline = try reader.readUInt8()
        underlineColor = hasUnderline != 0 ? try PaneColor(from: &reader) : nil
    }
}

extension PaneCell: PaneBinaryCodable {
    func write(to writer: inout PaneBinaryWriter) {
        writer.writeString(char)
        writer.writeInt8(width)
        attribute.write(to: &writer)
    }

    init(from reader: inout PaneBinaryReader) throws {
        char = try reader.readString()
        width = try reader.readInt8()
        attribute = try PaneAttribute(from: &reader)
    }
}

extension PaneTerminalSnapshot: PaneBinaryCodable {
    func write(to writer: inout PaneBinaryWriter) {
        writer.writeUInt16(UInt16(cols))
        writer.writeUInt16(UInt16(rows))
        writer.writeUInt16(UInt16(cursorX))
        writer.writeUInt16(UInt16(cursorY))
        writer.writeUInt8(isAlternate ? 1 : 0)
        writer.writeUInt16(UInt16(lines.count))
        for line in lines {
            writer.writeUInt16(UInt16(line.count))
            for cell in line {
                cell.write(to: &writer)
            }
        }
    }

    init(from reader: inout PaneBinaryReader) throws {
        cols = Int(try reader.readUInt16())
        rows = Int(try reader.readUInt16())
        cursorX = Int(try reader.readUInt16())
        cursorY = Int(try reader.readUInt16())
        isAlternate = try reader.readUInt8() != 0
        let lineCount = Int(try reader.readUInt16())
        lines = []
        lines.reserveCapacity(lineCount)
        for _ in 0..<lineCount {
            let cellCount = Int(try reader.readUInt16())
            var line: [PaneCell] = []
            line.reserveCapacity(cellCount)
            for _ in 0..<cellCount {
                line.append(try PaneCell(from: &reader))
            }
            lines.append(line)
        }
    }
}

extension PaneTerminalDelta: PaneBinaryCodable {
    func write(to writer: inout PaneBinaryWriter) {
        writer.writeUInt16(UInt16(startY))
        writer.writeUInt16(UInt16(endY))
        writer.writeUInt16(UInt16(cursorX))
        writer.writeUInt16(UInt16(cursorY))
        writer.writeUInt16(UInt16(lines.count))
        for line in lines {
            writer.writeUInt16(UInt16(line.count))
            for cell in line {
                cell.write(to: &writer)
            }
        }
    }

    init(from reader: inout PaneBinaryReader) throws {
        startY = Int(try reader.readUInt16())
        endY = Int(try reader.readUInt16())
        cursorX = Int(try reader.readUInt16())
        cursorY = Int(try reader.readUInt16())
        let lineCount = Int(try reader.readUInt16())
        lines = []
        lines.reserveCapacity(lineCount)
        for _ in 0..<lineCount {
            let cellCount = Int(try reader.readUInt16())
            var line: [PaneCell] = []
            line.reserveCapacity(cellCount)
            for _ in 0..<cellCount {
                line.append(try PaneCell(from: &reader))
            }
            lines.append(line)
        }
    }
}

extension PaneInputMessage: PaneBinaryCodable {
    func write(to writer: inout PaneBinaryWriter) {
        writer.writeData(data)
    }

    init(from reader: inout PaneBinaryReader) throws {
        data = try reader.readData()
    }
}

extension PaneResizeMessage: PaneBinaryCodable {
    func write(to writer: inout PaneBinaryWriter) {
        writer.writeUInt16(UInt16(cols))
        writer.writeUInt16(UInt16(rows))
    }

    init(from reader: inout PaneBinaryReader) throws {
        cols = Int(try reader.readUInt16())
        rows = Int(try reader.readUInt16())
    }
}

extension PaneWireMessage: PaneBinaryCodable {
    func write(to writer: inout PaneBinaryWriter) {
        writer.writeUInt8(type.binaryTag)
        switch type {
        case .snapshot:
            snapshot?.write(to: &writer)
        case .delta:
            delta?.write(to: &writer)
        case .input:
            input?.write(to: &writer)
        case .resize:
            resize?.write(to: &writer)
        case .request, .response:
            break // Not supported in binary format
        }
    }

    init(from reader: inout PaneBinaryReader) throws {
        let tag = try reader.readUInt8()
        guard let msgType = PaneMessageType(binaryTag: tag) else {
            throw PaneBinaryError.invalidTag
        }
        type = msgType
        request = nil
        response = nil
        snapshot = nil
        delta = nil
        input = nil
        resize = nil

        switch msgType {
        case .snapshot:
            snapshot = try PaneTerminalSnapshot(from: &reader)
        case .delta:
            delta = try PaneTerminalDelta(from: &reader)
        case .input:
            input = try PaneInputMessage(from: &reader)
        case .resize:
            resize = try PaneResizeMessage(from: &reader)
        case .request, .response:
            throw PaneBinaryError.invalidTag
        }
    }
}

extension PaneMessageType {
    var binaryTag: UInt8 {
        switch self {
        case .request: return 0
        case .response: return 1
        case .snapshot: return 2
        case .delta: return 3
        case .input: return 4
        case .resize: return 5
        }
    }

    init?(binaryTag: UInt8) {
        switch binaryTag {
        case 0: self = .request
        case 1: self = .response
        case 2: self = .snapshot
        case 3: self = .delta
        case 4: self = .input
        case 5: self = .resize
        default: return nil
        }
    }
}

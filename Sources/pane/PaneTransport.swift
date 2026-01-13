import Foundation

enum PaneWireFormat: UInt8 {
    case json = 0
    case binary = 1
}

final class PaneFramedConnection {
    private let handle: FileHandle
    private let encoder = JSONEncoder.paneEncoder()
    private let decoder = JSONDecoder.paneDecoder()
    private let writeQueue = DispatchQueue(label: "pane.connection.write")

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Send a message using JSON format (for requests/responses and debugging)
    func send(_ message: PaneWireMessage) throws {
        let data = try encoder.encode(message)
        try writeFrame(data, format: .json)
    }

    /// Send a message using binary format (for high-frequency terminal data)
    func sendBinary(_ message: PaneWireMessage) throws {
        var writer = PaneBinaryWriter()
        message.write(to: &writer)
        try writeFrame(writer.data, format: .binary)
    }

    /// Read a message, automatically detecting format
    func readMessage() throws -> PaneWireMessage? {
        guard let (data, format) = try readFrameWithFormat() else {
            return nil
        }
        switch format {
        case .json:
            return try decoder.decode(PaneWireMessage.self, from: data)
        case .binary:
            var reader = PaneBinaryReader(data: data)
            return try PaneWireMessage(from: &reader)
        }
    }

    func close() {
        handle.closeFile()
    }

    private func writeFrame(_ data: Data, format: PaneWireFormat) throws {
        // Frame format: [4 bytes length (big-endian)] [1 byte format] [payload]
        var length = UInt32(data.count + 1).bigEndian  // +1 for format byte
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(format.rawValue)
        frame.append(data)
        writeQueue.sync {
            handle.write(frame)
        }
    }

    private func readFrameWithFormat() throws -> (Data, PaneWireFormat)? {
        guard let lengthData = readExact(count: MemoryLayout<UInt32>.size) else {
            return nil
        }
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        if length == 0 {
            return (Data(), .json)
        }
        guard let payload = readExact(count: Int(length)) else {
            return nil
        }
        let formatByte = payload[0]
        let format = PaneWireFormat(rawValue: formatByte) ?? .json
        let data = payload.dropFirst()
        return (Data(data), format)
    }

    private func readExact(count: Int) -> Data? {
        var buffer = Data()
        while buffer.count < count {
            let chunk = handle.readData(ofLength: count - buffer.count)
            if chunk.isEmpty {
                return nil
            }
            buffer.append(chunk)
        }
        return buffer
    }
}

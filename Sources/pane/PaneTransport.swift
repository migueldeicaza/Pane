import Foundation

final class PaneFramedConnection {
    private let handle: FileHandle
    private let encoder = JSONEncoder.paneEncoder()
    private let decoder = JSONDecoder.paneDecoder()
    private let writeQueue = DispatchQueue(label: "pane.connection.write")

    init(handle: FileHandle) {
        self.handle = handle
    }

    func send(_ message: PaneWireMessage) throws {
        let data = try encoder.encode(message)
        try writeFrame(data)
    }

    func readMessage() throws -> PaneWireMessage? {
        guard let data = try readFrame() else {
            return nil
        }
        return try decoder.decode(PaneWireMessage.self, from: data)
    }

    func close() {
        handle.closeFile()
    }

    private func writeFrame(_ data: Data) throws {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(data)
        writeQueue.sync {
            handle.write(frame)
        }
    }

    private func readFrame() throws -> Data? {
        guard let lengthData = readExact(count: MemoryLayout<UInt32>.size) else {
            return nil
        }
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        if length == 0 {
            return Data()
        }
        return readExact(count: Int(length)) ?? Data()
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

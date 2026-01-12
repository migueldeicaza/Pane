import Foundation
import Logging

enum PaneLoggingError: Error, CustomStringConvertible {
    case fileHandleUnavailable(String)

    var description: String {
        switch self {
        case .fileHandleUnavailable(let path):
            return "failed to open log file at \(path)"
        }
    }
}

final class FileLogSink {
    let fileHandle: FileHandle
    let queue: DispatchQueue

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        self.queue = DispatchQueue(label: "pane.log.sink")
    }

    func write(_ line: String) {
        let data = Data(line.utf8)
        queue.async {
            self.fileHandle.write(data)
        }
    }
}

struct FileLogHandler: LogHandler {
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]
    let label: String
    private let sink: FileLogSink
    init(label: String, sink: FileLogSink) {
        self.label = label
        self.sink = sink
    }

    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { metadata[metadataKey] }
        set { metadata[metadataKey] = newValue }
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        if level < logLevel {
            return
        }
        var merged = self.metadata
        if let metadata {
            merged.merge(metadata, uniquingKeysWith: { _, new in new })
        }
        let metadataString = merged.isEmpty ? "" : " " + merged.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let output = "\(timestamp) [\(level)] \(label): \(message)\(metadataString)\n"
        sink.write(output)
    }
}

enum PaneLogging {
    static func configure(logToFile: Bool) throws -> String? {
        let logPath: String?
        let fileSink: FileLogSink?
        if logToFile {
            let path = try defaultLogPath()
            logPath = path
            fileSink = try openFileSink(path: path)
        } else {
            logPath = nil
            fileSink = nil
        }

        LoggingSystem.bootstrap { label in
            var handlers: [LogHandler] = [StreamLogHandler.standardError(label: label)]
            if let fileSink {
                handlers.append(FileLogHandler(label: label, sink: fileSink))
            }
            return MultiplexLogHandler(handlers)
        }

        return logPath
    }

    static func defaultLogPath() throws -> String {
        let dir = try PanePaths.runtimeDirectory()
        return dir.appendingPathComponent("pane.log").path
    }

    private static func openFileSink(path: String) throws -> FileLogSink {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw PaneLoggingError.fileHandleUnavailable(path)
        }
        try handle.seekToEnd()
        return FileLogSink(fileHandle: handle)
    }
}

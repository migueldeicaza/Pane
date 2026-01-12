import Foundation
import Darwin

enum PanePaths {
    static let socketName = "default"
    static let pidFileName = "pane.pid"

    static func runtimeDirectory() throws -> URL {
        let uid = geteuid()
        let path = "/tmp/pane-\(uid)"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let permissions: NSNumber = 0o700
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: permissions])
        _ = chmod(path, mode_t(0o700))
        return url
    }

    static func socketPath() throws -> String {
        let dir = try runtimeDirectory()
        return dir.appendingPathComponent(socketName).path
    }

    static func pidFilePath() throws -> String {
        let dir = try runtimeDirectory()
        return dir.appendingPathComponent(pidFileName).path
    }

    static func writePidFile(pid: Int32) throws {
        let path = try pidFilePath()
        let contents = "\(pid)\n"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        _ = chmod(path, mode_t(0o600))
    }

    static func readPidFile() throws -> Int32 {
        let path = try pidFilePath()
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed) else {
            throw PanePidError.invalidContents
        }
        return pid
    }
}

enum PanePidError: Error, CustomStringConvertible {
    case invalidContents

    var description: String {
        switch self {
        case .invalidContents:
            return "invalid pid file contents"
        }
    }
}

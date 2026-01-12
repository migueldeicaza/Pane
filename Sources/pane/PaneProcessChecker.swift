import Foundation
import Darwin

enum PaneProcessChecker {
    static func isAlive(pid: Int32) -> Bool {
        if pid <= 0 {
            return false
        }
        let result = kill(pid, 0)
        if result == 0 {
            return true
        }
        return errno == EPERM
    }
}

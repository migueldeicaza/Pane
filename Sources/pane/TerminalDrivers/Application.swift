import Foundation

enum Application {
    static var driver: ConsoleDriver = ConsoleDriver()
    static var onKeyEvent: ((KeyEvent) -> Void)?
    static var onMouseEvent: ((MouseEvent) -> Void)?
    static var onResize: (() -> Void)?

    static func setDriver(_ driver: ConsoleDriver) {
        self.driver = driver
    }

    static func processKeyEvent(event: KeyEvent) {
        onKeyEvent?(event)
    }

    static func processMouseEvent(mouseEvent: MouseEvent) {
        onMouseEvent?(mouseEvent)
    }

    static func terminalResized() {
        onResize?()
    }
}

import Foundation

struct Size: Equatable {
    var width: Int
    var height: Int

    static let empty = Size(width: 0, height: 0)
}

enum Key: Equatable {
    case controlSpace
    case controlA
    case controlB
    case controlC
    case controlD
    case controlE
    case controlF
    case controlG
    case controlH
    case controlI
    case controlJ
    case controlK
    case controlL
    case controlM
    case controlN
    case controlO
    case controlP
    case controlQ
    case controlR
    case controlS
    case controlT
    case controlU
    case controlV
    case controlW
    case controlX
    case controlY
    case controlZ
    case esc
    case fs
    case gs
    case rs
    case us
    case delete
    case deleteChar
    case insertChar
    case backspace
    case backtab
    case tab
    case cursorUp
    case cursorDown
    case cursorLeft
    case cursorRight
    case home
    case end
    case pageUp
    case pageDown
    case shiftCursorLeft
    case shiftCursorRight
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case letter(Character)
    case Unknown
}

struct KeyEvent {
    var key: Key
    var isAlt: Bool
    var isControl: Bool

    init(key: Key, isAlt: Bool = false, isControl: Bool = false) {
        self.key = key
        self.isAlt = isAlt
        self.isControl = isControl
    }
}

struct MouseEvent {
    var x: Int
    var y: Int
    var flags: MouseFlags
}

struct MouseFlags: OptionSet {
    let rawValue: UInt

    static let button1Pressed = MouseFlags(rawValue: 1 << 0)
    static let button1Released = MouseFlags(rawValue: 1 << 1)
    static let button1Clicked = MouseFlags(rawValue: 1 << 2)
    static let button2Pressed = MouseFlags(rawValue: 1 << 3)
    static let button2Released = MouseFlags(rawValue: 1 << 4)
    static let button2Clicked = MouseFlags(rawValue: 1 << 5)
    static let button3Pressed = MouseFlags(rawValue: 1 << 6)
    static let button3Released = MouseFlags(rawValue: 1 << 7)
    static let button3Clicked = MouseFlags(rawValue: 1 << 8)
    static let mousePosition = MouseFlags(rawValue: 1 << 9)
}

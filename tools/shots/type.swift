// type — type a string into whatever has keyboard focus.
//
//   type "Stock Room Desk"
//
// Posts each character as a key event carrying its unicode string, rather than mapping
// to virtual keycodes: the keycode for a given character depends on the active keyboard
// layout, and the unicode payload does not.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: type <text>\n".data(using: .utf8)!)
    exit(2)
}
let text = CommandLine.arguments.dropFirst().joined(separator: " ")
let source = CGEventSource(stateID: .hidSystemState)

for character in text.unicodeScalars {
    var utf16 = Array(String(character).utf16)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    else { continue }
    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    down.post(tap: .cghidEventTap)
    usleep(12_000)
    up.post(tap: .cghidEventTap)
    usleep(12_000)
}

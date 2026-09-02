// key — post a key press.
//
//   key <virtual keycode>        e.g. 53 = Escape, 36 = Return
//
// Used to dismiss a sheet. Clicking its Cancel button would work too, but a sheet is
// centred on its parent, so the button moves whenever the window is resized for a
// different shot -- and a sheet left open silently blocks every click after it.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let code = UInt16(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("usage: key <keycode>\n".data(using: .utf8)!)
    exit(2)
}
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
usleep(60_000)
CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)

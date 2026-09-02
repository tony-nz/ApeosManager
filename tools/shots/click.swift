// click — post a real mouse click at a screen point.
//
//   click <x> <y>
//
// AppleScript's `click at` does not reliably reach a menu bar extra, and
// `tell process whose unix id is N` picks the wrong process when the demo and the real
// app share a name. A posted HID event has neither problem.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 2,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    FileHandle.standardError.write("usage: click <x> <y>\n".data(using: .utf8)!)
    exit(2)
}
let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(120_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(90_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)

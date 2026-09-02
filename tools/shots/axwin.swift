// axwin — read or set a window's frame through the Accessibility API.
//
//   axwin <pid> <title|*> [x y w h]
//
// Saved window frames are whatever they were last dragged to, which is never the right
// shape for a capture. Fixed-size windows (SwiftUI `Settings`, and anything with
// .windowResizability(.contentSize)) ignore the size and keep their own, so the frame
// is read back and printed rather than assumed to have taken.
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count > 2, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: axwin <pid> <title|*> [x y w h]\n".data(using: .utf8)!)
    exit(2)
}
let wanted = args[2]
let app = AXUIElementCreateApplication(pid)

var value: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement] else {
    FileHandle.standardError.write("no windows (is Accessibility granted to this terminal?)\n".data(using: .utf8)!)
    exit(1)
}

for window in windows {
    var t: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &t)
    let name = (t as? String) ?? ""
    guard name == wanted || wanted == "*" else { continue }

    if args.count >= 7,
       let x = Double(args[3]), let y = Double(args[4]),
       let w = Double(args[5]), let h = Double(args[6]) {
        var origin = CGPoint(x: x, y: y)
        var size = CGSize(width: w, height: h)
        if let p = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
        }
        if let s = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    var pv: CFTypeRef?, sv: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pv)
    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sv)
    var origin = CGPoint.zero, size = CGSize.zero
    if let pv { AXValueGetValue(pv as! AXValue, .cgPoint, &origin) }
    if let sv { AXValueGetValue(sv as! AXValue, .cgSize, &size) }
    print("\(name)\t@\(Int(origin.x)),\(Int(origin.y))\t\(Int(size.width))x\(Int(size.height))")
}

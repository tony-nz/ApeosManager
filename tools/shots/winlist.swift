// winlist — list an app's on-screen windows, so `screencapture -l<id>` can take one.
//
//   winlist <owner substring> [pid]
//
// The pid filter is not optional in practice: while the demo is being captured the
// real app is usually still running under the same name, and the two are otherwise
// indistinguishable. Menu bar popovers appear as layer=101, ordinary windows as
// layer=0 -- which is how you tell the popover from the window behind it.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("usage: winlist <owner substring> [pid]\n".data(using: .utf8)!)
    exit(2)
}
let owner = args[1]
let target = args.count > 2 ? Int(args[2]) : nil

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }

for w in raw {
    let name = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    guard name.localizedCaseInsensitiveContains(owner) else { continue }
    if let target, pid != target { continue }
    let id = w[kCGWindowNumber as String] as? Int ?? -1
    let title = w[kCGWindowName as String] as? String ?? ""
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    print("id=\(id)\tpid=\(pid)\tlayer=\(layer)\t\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))\t@\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0))\t\(title)")
}

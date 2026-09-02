// focus — bring one process to the front, by pid.
//
//   focus <pid>
//
// Needed because the apps are launched from the shell rather than with `open`, so they
// start behind the terminal, and a capture leaves them there. A click on an unfocused
// window is spent activating it rather than pressing anything, which is what made every
// second shot in a run identical to the one before it.
//
// By pid rather than by name: while the demo is captured the real app is usually also
// running, under the same name.
import AppKit

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid) else {
    FileHandle.standardError.write("usage: focus <pid>\n".data(using: .utf8)!)
    exit(2)
}
app.activate(options: [.activateAllWindows])
usleep(300_000)
print(app.isActive ? "active" : "not active")

import AppKit
import SwiftUI

@main
struct ApeosManagerApp: App {
    @StateObject private var store = PrinterStore()
    @StateObject private var fleet: Fleet

    init() {
        let store = PrinterStore()
        _store = StateObject(wrappedValue: store)
        _fleet = StateObject(wrappedValue: Fleet(store: store))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView().environmentObject(store).environmentObject(fleet)
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About Apeos Manager") { AboutPanel.show() }
            }
        }

        MenuBarExtra {
            MenuBarPanel().environmentObject(store).environmentObject(fleet)
        } label: {
            Image(systemName: "printer.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The stock AppKit About panel, with the credits pane filled in.
///
/// `orderFrontStandardAboutPanel` reads credits only from a Credits.rtf/html resource,
/// so the text is passed as an option instead -- three lines do not warrant shipping an
/// RTF file that no one would remember to keep in step with the code.
enum AboutPanel {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static let repository = URL(string: "https://github.com/tony-nz/ApeosManager")

    private static var credits: NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = 8

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centred,
        ]

        let text = NSMutableAttributedString(
            string: "Fleet management for FUJIFILM Apeos and ApeosPort multifunction printers.\n",
            attributes: body)

        let link = NSMutableAttributedString(string: "github.com/tony-nz/ApeosManager\n",
                                             attributes: body)
        if let repository {
            link.addAttribute(.link, value: repository,
                              range: NSRange(location: 0, length: link.length - 1))
        }
        text.append(link)

        // The app talks to Apeos hardware over an API the vendor never published; say
        // plainly that this is not a FUJIFILM product.
        text.append(NSAttributedString(
            string: "Not affiliated with or endorsed by FUJIFILM Business Innovation.",
            attributes: body))

        return text
    }
}

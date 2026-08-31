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
        .commands { SidebarCommands() }

        MenuBarExtra {
            MenuBarPanel().environmentObject(store).environmentObject(fleet)
        } label: {
            Image(systemName: "printer.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

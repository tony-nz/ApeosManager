import Combine
import Foundation
import SwiftUI

/// Owns one DeviceViewModel per printer so the per-printer screens and the fleet-wide
/// screens share a single session, rather than each view signing in again.
@MainActor
final class Fleet: ObservableObject {
    @Published private(set) var devices: [UUID: DeviceViewModel] = [:]
    @Published var isLoadingAll = false

    private let store: PrinterStore
    /// Each DeviceViewModel is its own ObservableObject, so a view observing only the
    /// Fleet never re-renders when a printer's users or supplies change. Forward every
    /// child's change notification so the fleet-wide screens stay live.
    private var childSubscriptions: [UUID: AnyCancellable] = [:]

    init(store: PrinterStore) { self.store = store }

    func viewModel(for printer: Printer) -> DeviceViewModel {
        if let existing = devices[printer.id], existing.printer.host == printer.host {
            return existing
        }
        let vm = DeviceViewModel(printer: printer, password: store.password(for: printer))
        vm.passwordLocked = store.passwordLocked(for: printer)
        devices[printer.id] = vm
        childSubscriptions[printer.id] = vm.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return vm
    }

    /// View models for the current printer list, in sidebar order.
    func ordered() -> [DeviceViewModel] {
        store.printers.map { viewModel(for: $0) }
    }

    /// Connects every printer concurrently. Individual failures are held on each
    /// device's own view model, so one unreachable printer cannot stall the rest.
    func connectAll() async {
        isLoadingAll = true
        defer { isLoadingAll = false }
        let vms = ordered()
        await withTaskGroup(of: Void.self) { group in
            for vm in vms { group.addTask { await vm.connect() } }
        }
    }

    func refreshAll() async {
        isLoadingAll = true
        defer { isLoadingAll = false }
        let vms = ordered()
        await withTaskGroup(of: Void.self) { group in
            for vm in vms {
                group.addTask {
                    await vm.refresh()
                    await vm.loadDirectory()
                }
            }
        }
    }

    func drop(_ printer: Printer) {
        devices[printer.id] = nil
        childSubscriptions[printer.id] = nil
    }
}

/// A user as seen across the whole fleet.
struct FleetUser: Identifiable, Hashable {
    var userID: String
    var name: String
    var type: String
    var roles: [String]
    /// Printer ids where this account exists.
    var presentOn: Set<UUID>

    var id: String { userID }
}

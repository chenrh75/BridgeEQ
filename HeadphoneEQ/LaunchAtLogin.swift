import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status

    var enabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) throws {
        refresh()
        defer { refresh() }
        if enabled {
            if !self.enabled { try SMAppService.mainApp.register() }
        } else if status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

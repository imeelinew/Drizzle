import Foundation
import ServiceManagement

enum LoginItemController {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard !isEnabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard isEnabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}

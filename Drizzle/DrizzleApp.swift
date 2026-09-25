import SwiftUI

@main
struct DrizzleApp: App {
    var body: some Scene {
        MenuBarExtra {
            QuotaMenu()
        } label: {
            Text("Drizzle")
        }
        .menuBarExtraStyle(.window)
    }
}

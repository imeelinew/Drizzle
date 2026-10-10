import AppKit

@main
enum DrizzleApp {
    @MainActor
    static func main() {
        autoreleasepool {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.delegate = delegate
            withExtendedLifetime(delegate) {
                application.run()
            }
        }
    }
}

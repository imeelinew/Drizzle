import AppKit

@MainActor
enum ProviderBrandIcon {
    private static let size = NSSize(width: 18, height: 18)
    private static var cache: [UsageProvider: NSImage] = [:]

    /// Lazy-loaded resource bundle for provider icons.
    private static let resourceBundle: Bundle? = .main

    static func image(for provider: UsageProvider) -> NSImage? {
        if let cached = self.cache[provider] {
            return cached
        }

        let baseName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.iconResourceName
        guard let bundle = self.resourceBundle else {
            return nil
        }
        guard let url = bundle.url(forResource: baseName, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.size = self.size
        image.isTemplate = true
        self.cache[provider] = image
        return image
    }

}

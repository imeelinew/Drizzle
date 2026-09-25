import AppKit
import SwiftUI

private enum SettingsWindowMetrics {
    static let contentSize = NSSize(width: 778, height: 509)
    static let sidebarWidth: CGFloat = 196
}

enum SettingsPage: String, CaseIterable, Hashable, Identifiable {
    case codex
    case claude
    case cursor
    case zai
    case openrouter
    case general

    var id: String { self.rawValue }

    enum Group: String, CaseIterable {
        case providers = "供应商"
        case preferences = "偏好"
    }

    var group: Group {
        self == .general ? .preferences : .providers
    }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .zai: "z.ai / GLM"
        case .openrouter: "OpenRouter"
        case .general: "通用"
        }
    }

    @MainActor
    var icon: NSImage? {
        if self == .general {
            return NSImage(systemSymbolName: "gearshape", accessibilityDescription: self.title)
        }
        guard let provider = UsageProvider(rawValue: self.rawValue) else { return nil }
        return ProviderBrandIcon.image(for: provider)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: DrizzleStore
    private var window: NSWindow?

    init(store: DrizzleStore) {
        self.store = store
    }

    func show() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsRootView(store: self.store))
        let win = SettingsWindow(contentViewController: hosting)
        win.title = "设置"
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.collectionBehavior = [.fullScreenNone, .fullScreenDisallowsTiling]
        win.isReleasedWhenClosed = false
        win.setContentSize(SettingsWindowMetrics.contentSize)
        win.minSize = win.frame.size
        win.maxSize = win.frame.size
        win.center()
        win.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        win.standardWindowButton(.zoomButton)?.isEnabled = false
        win.delegate = self
        self.window = win
        self.installCommandWCloseView(on: win)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        (notification.object as? NSWindow)?.delegate = nil
        self.window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func installCommandWCloseView(on window: NSWindow) {
        guard let content = window.contentView else { return }
        let view = CommandWCloseView(frame: content.bounds)
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
    }
}

private final class SettingsWindow: NSWindow {
    override func miniaturize(_ sender: Any?) {}
    override func zoom(_ sender: Any?) {}
    override func toggleFullScreen(_ sender: Any?) {}
}

struct SettingsRootView: View {
    @Bindable var store: DrizzleStore
    @State private var page: SettingsPage = .codex
    @State private var backStack: [SettingsPage] = []
    @State private var forwardStack: [SettingsPage] = []
    @State private var applyingHistory = false

    var body: some View {
        NavigationSplitView {
            List(selection: self.$page) {
                ForEach(SettingsPage.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(SettingsPage.allCases.filter { $0.group == group }) { page in
                            Label {
                                Text(page.title)
                            } icon: {
                                self.sidebarIcon(page.icon)
                            }
                            .listItemTint(.preferred(Color.secondary))
                            .tag(page)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .background(SourceListSelection())
            .navigationSplitViewColumnWidth(
                min: SettingsWindowMetrics.sidebarWidth,
                ideal: SettingsWindowMetrics.sidebarWidth,
                max: SettingsWindowMetrics.sidebarWidth)
        } detail: {
            NavigationStack {
                self.detail
                    .navigationTitle(self.page.title)
            }
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button(action: self.goBack) {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(self.backStack.isEmpty)
                    Button(action: self.goForward) {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(self.forwardStack.isEmpty)
                }
                .controlGroupStyle(.navigation)
            }
        }
        .onChange(of: self.page) { previous, _ in
            guard !self.applyingHistory else {
                self.applyingHistory = false
                return
            }
            self.backStack.append(previous)
            self.forwardStack.removeAll()
        }
    }

    private func goBack() {
        guard let page = self.backStack.popLast() else { return }
        self.forwardStack.append(self.page)
        self.applyingHistory = true
        self.page = page
    }

    private func goForward() {
        guard let page = self.forwardStack.popLast() else { return }
        self.backStack.append(self.page)
        self.applyingHistory = true
        self.page = page
    }

    private func sidebarIcon(_ image: NSImage?) -> some View {
        Image(nsImage: image ?? NSImage())
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 16, height: 16)
    }

    @ViewBuilder
    private var detail: some View {
        switch self.page {
        case .codex:
            ProviderStatusPage(store: self.store, provider: .codex)
        case .claude:
            ProviderStatusPage(store: self.store, provider: .claude)
        case .cursor:
            CredentialPage(store: self.store, provider: .cursor, title: "Cookie", text: self.$store.cursorCookie, prompt: "Cookie: …") {
                self.store.saveSecrets()
                await self.store.refresh(provider: .cursor)
            }
        case .zai:
            ZaiSettingsPage(store: self.store)
        case .openrouter:
            CredentialPage(store: self.store, provider: .openrouter, title: "API key", text: self.$store.openRouterKey, prompt: "sk-or-v1-…") {
                self.store.saveSecrets()
                await self.store.refresh(provider: .openrouter)
            }
        case .general:
            GeneralSettingsPage(store: self.store)
        }
    }
}

struct ProviderStatusPage: View {
    @Bindable var store: DrizzleStore
    let provider: UsageProvider

    var body: some View {
        Form {
            Section(self.providerTitle) {
                ProviderEnabledRow(store: self.store, provider: self.provider)
                if let message = self.store.results[self.provider]?.message {
                    LabeledContent("状态") {
                        Text(message).foregroundStyle(.red)
                    }
                } else if let updated = self.store.results[self.provider]?.updatedAt {
                    LabeledContent("最近更新") {
                        Text(UsageFormatter.updatedString(from: updated))
                    }
                }
                Button("刷新") {
                    Task { await self.store.refresh(provider: self.provider) }
                }
                .disabled(self.store.isRefreshing)
            }
        }
        .formStyle(.grouped)
        .settingsContentMargins()
    }

    private var providerTitle: String {
        ProviderDescriptorRegistry.descriptor(for: self.provider).metadata.displayName
    }
}

struct CredentialPage: View {
    @Bindable var store: DrizzleStore
    let provider: UsageProvider
    let title: String
    @Binding var text: String
    let prompt: String
    let onCommit: () async -> Void

    var body: some View {
        Form {
            Section("供应商") {
                ProviderEnabledRow(store: self.store, provider: self.provider)
            }
            Section(self.title) {
                SecureField(self.prompt, text: self.$text)
                    .onSubmit { Task { await self.onCommit() } }
                Button("保存并刷新") {
                    Task { await self.onCommit() }
                }
            }
        }
        .formStyle(.grouped)
        .settingsContentMargins()
    }
}

struct ZaiSettingsPage: View {
    @Bindable var store: DrizzleStore

    var body: some View {
        Form {
            Section("z.ai / GLM") {
                ProviderEnabledRow(store: self.store, provider: .zai)
            }
            Section("API key") {
                SecureField("API key", text: self.$store.zaiKey)
                Picker("区域", selection: self.$store.zaiRegion) {
                    Text("Global").tag("global")
                    Text("BigModel CN").tag("bigmodel-cn")
                }
                Button("保存并刷新") {
                    self.store.saveSecrets()
                    Task { await self.store.refresh(provider: .zai) }
                }
            }
            if let message = self.store.results[.zai]?.message {
                Section {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .settingsContentMargins()
    }
}

struct GeneralSettingsPage: View {
    @Bindable var store: DrizzleStore
    @State private var launchAtLogin = LoginItemController.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("系统") {
                Toggle("登录时启动", isOn: Binding(
                    get: { self.launchAtLogin },
                    set: { enabled in
                        do {
                            try LoginItemController.setEnabled(enabled)
                            self.launchAtLogin = LoginItemController.isEnabled
                            self.launchError = nil
                        } catch {
                            self.launchAtLogin = LoginItemController.isEnabled
                            self.launchError = error.localizedDescription
                        }
                    }))
                if let launchError { Text(launchError).foregroundStyle(.red) }
            }
            Section("刷新") {
                LabeledContent("刷新间隔") {
                    Picker("刷新间隔", selection: Binding(
                        get: { self.store.refreshInterval },
                        set: { self.store.setRefreshInterval($0) })) {
                        ForEach(RefreshInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .buttonStyle(.bordered)
                }
                Toggle("打开菜单时刷新", isOn: Binding(
                    get: { self.store.refreshOnOpen },
                    set: { self.store.setRefreshOnOpen($0) }))
            }
            Section("菜单栏") {
                LabeledContent("供应商") {
                    Picker("供应商", selection: Binding(
                        get: { self.store.menuBarProvider },
                        set: { self.store.setMenuBarProvider($0) })) {
                        ForEach(UsageProvider.allCases, id: \.self) { provider in
                            Text(ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName)
                                .tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .buttonStyle(.bordered)
                }
                LabeledContent("额度") {
                    Picker("额度", selection: Binding(
                        get: { self.store.menuBarMetric },
                        set: { self.store.setMenuBarMetric($0) })) {
                        ForEach(MenuBarMetric.options(for: self.store.menuBarProvider)) { metric in
                            Text(metric.title).tag(metric)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .buttonStyle(.bordered)
                }
                LabeledContent("百分比") {
                    Picker("百分比", selection: Binding(
                        get: { self.store.menuBarPercentMode },
                        set: { self.store.setMenuBarPercentMode($0) })) {
                        ForEach(MenuBarPercentMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
        .settingsContentMargins()
    }
}

struct ProviderEnabledRow: View {
    @Bindable var store: DrizzleStore
    let provider: UsageProvider

    var body: some View {
        Toggle("启用", isOn: Binding(
            get: { self.store.isEnabled(self.provider) },
            set: { self.store.setEnabled($0, for: self.provider) }))
    }
}

private struct SourceListSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SourceListSelectionView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SourceListSelectionView)?.apply()
    }
}

private final class SourceListSelectionView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.apply()
    }

    func apply() {
        DispatchQueue.main.async { [weak self] in
            guard let table = self?.enclosingTable else { return }
            table.style = .sourceList
        }
    }

    private var enclosingTable: NSTableView? {
        if let table = self.enclosingScrollView?.documentView as? NSTableView { return table }
        var ancestor: NSView? = self
        while let current = ancestor {
            if let table = current as? NSTableView { return table }
            if let table = current.enclosingScrollView?.documentView as? NSTableView { return table }
            ancestor = current.superview
        }
        return self.window?.contentView?.tables.min { lhs, rhs in
            lhs.convert(lhs.bounds, to: nil).minX < rhs.convert(rhs.bounds, to: nil).minX
        }
    }
}

private extension NSView {
    var tables: [NSTableView] {
        var found: [NSTableView] = []
        if let table = self as? NSTableView { found.append(table) }
        for subview in self.subviews { found.append(contentsOf: subview.tables) }
        return found
    }
}

private final class CommandWCloseView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command, event.keyCode == 13 else {
            return super.performKeyEquivalent(with: event)
        }
        self.window?.performClose(nil)
        return true
    }
}

extension View {
    func settingsContentMargins() -> some View {
        self
            .contentMargins(.horizontal, 18, for: .scrollContent)
            .contentMargins(.top, 0, for: .scrollContent)
    }
}

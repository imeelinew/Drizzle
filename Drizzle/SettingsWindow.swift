import AppKit
import SwiftUI

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
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsRootView(store: self.store))
        let win = NSWindow(contentViewController: hosting)
        win.title = "设置"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.collectionBehavior = [.fullScreenNone, .fullScreenDisallowsTiling]
        win.isReleasedWhenClosed = false
        let size = NSSize(width: 950, height: 680)
        win.minSize = win.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: 860, height: 560))).size
        win.setFrame(NSRect(origin: win.frame.origin, size: size), display: false)
        win.center()
        win.delegate = self
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        (notification.object as? NSWindow)?.delegate = nil
        self.window = nil
    }
}

struct SettingsRootView: View {
    @Bindable var store: DrizzleStore
    @State private var page: SettingsPage = .codex
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false

    var body: some View {
        NavigationSplitView(columnVisibility: self.$columnVisibility) {
            SettingsSidebar(selected: self.$page)
                .navigationSplitViewColumnWidth(min: 150, ideal: 180)
        } detail: {
            NavigationStack {
                self.detail
            }
            .navigationTitle(self.page.title)
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("侧边栏", systemImage: "sidebar.left") {
                    withAnimation {
                        self.columnVisibility = self.columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                }
                .help("显示或隐藏侧边栏")
            }
        }
        .toolbarBackgroundVisibility(self.windowTransparencyEnabled ? .hidden : .automatic, for: .windowToolbar)
        .background {
            WindowTransparencyConfigurator(enabled: self.windowTransparencyEnabled)
                .frame(width: 0, height: 0)
            if self.windowTransparencyEnabled {
                WindowBackgroundBlur()
                    .ignoresSafeArea()
            }
        }
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
    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false

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
        .scrollContentBackground(self.windowTransparencyEnabled ? .hidden : .automatic)
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
    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false

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
        .scrollContentBackground(self.windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
    }
}

struct ZaiSettingsPage: View {
    @Bindable var store: DrizzleStore
    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false

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
        .scrollContentBackground(self.windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
    }
}

struct GeneralSettingsPage: View {
    @Bindable var store: DrizzleStore
    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false
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
            Section("窗口") {
                Toggle("窗口透明", isOn: self.$windowTransparencyEnabled)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(self.windowTransparencyEnabled ? .hidden : .automatic)
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

struct SettingsSidebar: NSViewRepresentable {
    @Binding var selected: SettingsPage

    func makeCoordinator() -> Coordinator {
        Coordinator(selected: self.$selected)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.selected = self.$selected
        context.coordinator.syncSelection()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var selected: Binding<SettingsPage>
        private weak var tableView: NSTableView?
        private let items: [Item]
        private var isSyncing = false

        init(selected: Binding<SettingsPage>) {
            self.selected = selected
            var rows: [Item] = []
            for group in SettingsPage.Group.allCases {
                rows.append(.header(group.rawValue))
                rows.append(contentsOf: SettingsPage.allCases.filter { $0.group == group }.map(Item.page))
            }
            self.items = rows
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

            let table = NSTableView()
            table.style = .sourceList
            table.selectionHighlightStyle = .regular
            table.headerView = nil
            table.backgroundColor = .clear
            table.rowSizeStyle = .custom
            table.intercellSpacing = NSSize(width: 0, height: 2)
            table.floatsGroupRows = false
            table.allowsEmptySelection = false
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.dataSource = self
            table.delegate = self
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            scrollView.documentView = table
            self.tableView = table
            self.syncSelection()
            return scrollView
        }

        func numberOfRows(in tableView: NSTableView) -> Int { self.items.count }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            if case .header = self.items[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            if case .page = self.items[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if case .header = self.items[row] { return 24 }
            return 30
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            SidebarRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch self.items[row] {
            case let .header(title):
                let cell = tableView.makeView(withIdentifier: SidebarHeaderCell.reuseID, owner: self) as? SidebarHeaderCell
                    ?? SidebarHeaderCell()
                cell.configure(title: title)
                return cell
            case let .page(page):
                let cell = tableView.makeView(withIdentifier: SidebarPageCell.reuseID, owner: self) as? SidebarPageCell
                    ?? SidebarPageCell()
                cell.configure(title: page.title, icon: page.icon)
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !self.isSyncing, let table = notification.object as? NSTableView,
                  self.items.indices.contains(table.selectedRow),
                  case let .page(page) = self.items[table.selectedRow]
            else { return }
            self.selected.wrappedValue = page
        }

        func syncSelection() {
            guard let tableView else { return }
            guard let row = self.items.firstIndex(where: {
                if case let .page(page) = $0 { return page == self.selected.wrappedValue }
                return false
            }) else { return }
            if tableView.selectedRow == row { return }
            self.isSyncing = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            self.isSyncing = false
        }

        enum Item {
            case header(String)
            case page(SettingsPage)
        }
    }
}

private final class SidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { super.isEmphasized = false }
    }
}

private final class SidebarHeaderCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("SettingsSidebarHeaderCell")
    private let titleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.identifier = Self.reuseID
        self.titleField.font = .systemFont(ofSize: 11, weight: .semibold)
        self.titleField.textColor = .secondaryLabelColor
        self.titleField.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.titleField)
        NSLayoutConstraint.activate([
            self.titleField.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 13),
            self.titleField.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor, constant: -9),
            self.titleField.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(title: String) {
        self.titleField.stringValue = title
    }
}

private final class SidebarPageCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("SettingsSidebarPageCell")
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.identifier = Self.reuseID
        self.iconView.imageScaling = .scaleProportionallyDown
        self.iconView.translatesAutoresizingMaskIntoConstraints = false
        self.titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        self.titleField.lineBreakMode = .byTruncatingTail
        self.titleField.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.iconView)
        self.addSubview(self.titleField)
        NSLayoutConstraint.activate([
            self.iconView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 3),
            self.iconView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.iconView.widthAnchor.constraint(equalToConstant: 18),
            self.iconView.heightAnchor.constraint(equalToConstant: 18),
            self.titleField.leadingAnchor.constraint(equalTo: self.iconView.trailingAnchor, constant: 8),
            self.titleField.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -14),
            self.titleField.centerYAnchor.constraint(equalTo: self.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(title: String, icon: NSImage?) {
        self.titleField.stringValue = title
        self.iconView.image = icon
        self.iconView.contentTintColor = .labelColor
    }
}

struct WindowBackgroundBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct WindowTransparencyConfigurator: NSViewRepresentable {
    var enabled: Bool

    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            if self.enabled {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.titlebarAppearsTransparent = true
            } else {
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
                window.titlebarAppearsTransparent = false
            }
            window.invalidateShadow()
        }
    }

    private final class Probe: NSView {
        override var isOpaque: Bool { false }
    }
}

extension View {
    func settingsContentMargins() -> some View {
        self
            .contentMargins(.horizontal, 18, for: .scrollContent)
            .contentMargins(.top, 0, for: .scrollContent)
    }
}

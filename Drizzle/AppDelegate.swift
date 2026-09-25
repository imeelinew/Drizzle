import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = DrizzleStore()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var switcher: ProviderSwitcherView?
    private var cardItems: [NSMenuItem] = []
    private var actionsSeparator: NSMenuItem?
    private var isMenuOpen = false
    private var settings: SettingsWindowController!
    private var refreshTask: Task<Void, Never>?
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        self.settings = SettingsWindowController(store: self.store)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.button?.imagePosition = .imageLeft
        self.statusItem.button?.imageScaling = .scaleProportionallyDown
        self.menu.delegate = self
        self.menu.autoenablesItems = false
        self.statusItem.menu = self.menu
        self.rebuildMenu()
        self.store.onChange = { [weak self] in
            self?.updateIcon()
            if self?.isMenuOpen == true {
                self?.switcher?.updateQuotaIndicators()
                self?.rebuildCards()
            }
        }
        self.store.onRefreshIntervalChange = { [weak self] in
            self?.startRefreshLoop()
        }
        self.updateIcon()
        self.startRefreshLoop()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        self.settings.show()
        return true
    }

    private func startRefreshLoop() {
        self.refreshTask?.cancel()
        guard self.store.refreshInterval != .manual else { return }
        self.refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.store.refresh()
                let seconds = self.store.refreshInterval.rawValue
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        self.isMenuOpen = true
        self.rebuildMenu()
        if self.store.refreshOnOpen {
            Task { await self.store.refresh() }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        self.isMenuOpen = false
    }

    private func rebuildMenu() {
        self.menu.removeAllItems()
        self.cardItems.removeAll()

        let width: CGFloat = 310
        let switcher = ProviderSwitcherView(
            providers: self.store.visibleProviders,
            selected: self.store.selection,
            includesOverview: true,
            width: width,
            showsIcons: true,
            iconProvider: { ProviderBrandIcon.image(for: $0) ?? NSImage() },
            weeklyRemainingProvider: { [weak self] provider in
                if provider == .cursor {
                    return self?.store.cursorAutoWindow?.remainingPercent
                }
                return self?.store.windows(for: provider).last?.remainingPercent
            },
            onSelect: { [weak self] selection in
                guard let self else { return }
                self.store.selection = selection
                self.switcher?.updateSelection(selection)
                self.rebuildCards()
            })
        self.switcher = switcher
        let switcherItem = NSMenuItem()
        switcherItem.title = ""
        switcherItem.view = switcher
        switcherItem.isEnabled = false
        self.menu.addItem(switcherItem)

        let separator = NSMenuItem.separator()
        self.actionsSeparator = separator
        self.menu.addItem(separator)
        self.menu.addItem(self.actionItem("刷新", #selector(refreshAction)))
        let updateItem = NSMenuItem(
            title: "检查更新…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        updateItem.target = self.updaterController
        updateItem.isEnabled = self.updaterController.updater.canCheckForUpdates
        self.menu.addItem(updateItem)
        self.menu.addItem(self.actionItem("设置…", #selector(settingsAction)))
        self.menu.addItem(self.actionItem("关于 Drizzle", #selector(aboutAction)))
        self.menu.addItem(self.actionItem("退出", #selector(quitAction)))
        self.rebuildCards()
    }

    private func rebuildCards() {
        for item in self.cardItems {
            self.menu.removeItem(item)
        }
        self.cardItems.removeAll()
        guard let actionsSeparator else { return }
        var index = self.menu.index(of: actionsSeparator)
        let providers: [UsageProvider]
        switch self.store.selection {
        case .overview:
            providers = self.store.visibleProviders
        case let .provider(id):
            providers = id.firstPartyProvider.flatMap { self.store.isEnabled($0) ? [$0] : nil } ?? []
        }
        if providers.isEmpty {
            let item = NSMenuItem(title: "在设置中开启供应商", action: nil, keyEquivalent: "")
            item.isEnabled = false
            self.menu.insertItem(item, at: index)
            self.cardItems.append(item)
            return
        }
        for (offset, provider) in providers.enumerated() {
            let result = self.store.results[provider]
            let card = ProviderQuotaCard(
                provider: provider,
                windows: result?.windows ?? [],
                windowTitles: result?.windowTitles ?? [],
                plan: result?.plan,
                message: result?.message,
                updatedAt: result?.updatedAt,
                balance: result?.balance)
                .frame(width: 310, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            let hosting = NSHostingView(rootView: card)
            hosting.frame = NSRect(x: 0, y: 0, width: 310, height: 1)
            hosting.layoutSubtreeIfNeeded()
            hosting.frame.size.height = max(1, ceil(hosting.fittingSize.height))
            let item = NSMenuItem()
            item.title = ""
            item.view = hosting
            item.isEnabled = false
            self.menu.insertItem(item, at: index)
            self.cardItems.append(item)
            index += 1
            if offset < providers.count - 1 {
                let divider = NSMenuItem.separator()
                self.menu.insertItem(divider, at: index)
                self.cardItems.append(divider)
                index += 1
            }
        }
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func refreshAction() {
        Task { await self.store.refresh() }
    }

    @objc private func settingsAction() {
        self.settings.show()
    }

    @objc private func aboutAction() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    private func updateIcon() {
        guard let button = self.statusItem.button else { return }
        button.image = ProviderBrandIcon.image(for: self.store.menuBarProvider)
        if let percent = self.store.menuBarPercent, percent.isFinite {
            button.title = " \(Int(max(0, min(100, percent)).rounded()))%"
        } else {
            button.title = " —"
        }
    }
}

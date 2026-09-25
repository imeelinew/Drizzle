import AppKit
import SwiftUI

struct QuotaMenu: View {
    @State private var selection: ProviderSwitcherSelection = .overview
    @State private var windows: [UsageProvider: [RateWindow]] = [:]
    @State private var plans: [UsageProvider: String] = [:]
    @State private var messages: [UsageProvider: String] = [:]
    @State private var updatedAt: [UsageProvider: Date] = [:]

    private let providers = UsageProvider.allCases
    private let width: CGFloat = 310

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderSwitcherRepresentable(
                providers: self.providers,
                selected: self.selection,
                width: self.width,
                weeklyRemaining: { provider in
                    self.windows[provider]?.last?.remainingPercent
                },
                onSelect: { self.selection = $0 })
                .frame(width: self.width)
            self.content
                .frame(width: self.width, alignment: .leading)
        }
        .frame(width: self.width)
        .task { await self.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch self.selection {
        case .overview:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(self.providers, id: \.rawValue) { provider in
                    ProviderQuotaCard(
                        provider: provider,
                        windows: self.windows[provider] ?? [],
                        plan: self.plans[provider],
                        message: self.messages[provider],
                        updatedAt: self.updatedAt[provider])
                    if provider != self.providers.last {
                        Divider()
                    }
                }
            }
        case let .provider(instanceID):
            if let provider = instanceID.firstPartyProvider {
                ProviderQuotaCard(
                    provider: provider,
                    windows: self.windows[provider] ?? [],
                    plan: self.plans[provider],
                    message: self.messages[provider],
                    updatedAt: self.updatedAt[provider])
            }
        }
    }

    private func refresh() async {
        let results = await ProviderFetch.fetchAll()
        for result in results {
            self.windows[result.provider] = result.windows
            self.plans[result.provider] = result.plan
            self.messages[result.provider] = result.message
            self.updatedAt[result.provider] = result.updatedAt
        }
    }
}

struct ProviderQuotaCard: View {
    let provider: UsageProvider
    let windows: [RateWindow]
    let plan: String?
    let message: String?
    let updatedAt: Date?

    private var metadata: ProviderMetadata {
        ProviderDescriptorRegistry.descriptor(for: self.provider).metadata
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UsageMenuCardLayout.headerContentSpacing) {
            self.header
            if self.message != nil || !self.metrics.isEmpty {
                Divider()
            }
            if let message = self.message, self.metrics.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.error(false))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, UsageMenuCardLayout.usageSectionTopPadding)
            }
            if !self.metrics.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(self.metrics) { metric in
                        MetricRow(
                            metric: metric,
                            layoutMetric: metric,
                            title: UsageMenuCardView.popupMetricTitle(provider: self.provider, metric: metric),
                            progressColor: self.metadata.color.swiftUI)
                    }
                }
                .padding(.top, UsageMenuCardLayout.usageSectionTopPadding)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.top, UsageMenuCardLayout.headerOnlyVerticalPadding)
        .padding(.bottom, UsageMenuCardLayout.sectionBottomPadding)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: UsageMenuCardLayout.headerLineSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                Text(self.metadata.displayName)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                Text(self.subtitle)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(false))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()
                if let plan = self.plan, !plan.isEmpty {
                    Text(plan)
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(MenuHighlightStyle.accent(false))
                        .lineLimit(1)
                        .layoutPriority(2)
                }
            }
        }
    }

    private var subtitle: String {
        guard let updatedAt else { return L("Updated just now") }
        return UsageFormatter.updatedString(from: updatedAt)
    }

    private var metrics: [UsageMenuCardView.Model.Metric] {
        self.windows.enumerated().map { index, window in
            let title = index == 0 ? L(self.metadata.sessionLabel) : L(self.metadata.weeklyLabel)
            let pace = Self.paceDetail(provider: self.provider, window: window, isSession: index == 0)
            return UsageMenuCardView.Model.Metric(
                id: index == 0 ? "primary" : "secondary",
                title: title,
                percent: window.usedPercent,
                percentStyle: .used,
                resetText: UsageFormatter.resetLine(for: window, style: .countdown),
                detailText: nil,
                detailLeftText: pace?.left,
                detailRightText: pace?.right,
                pacePercent: pace?.pacePercent,
                paceOnTop: pace?.paceOnTop ?? true)
        }
    }

    private struct PaceBits {
        let left: String
        let right: String?
        let pacePercent: Double?
        let paceOnTop: Bool
    }

    private static func paceDetail(provider: UsageProvider, window: RateWindow, isSession: Bool) -> PaceBits? {
        let detail: UsagePaceText.WeeklyDetail?
        if isSession {
            detail = UsagePaceText.sessionDetail(provider: provider, window: window)
        } else if let pace = UsagePace.weekly(window: window, now: .now, defaultWindowMinutes: 10080),
                  pace.expectedUsedPercent >= 3 || pace.etaSeconds == 0,
                  window.remainingPercent > 0
        {
            detail = UsagePaceText.weeklyDetail(provider: provider, pace: pace)
        } else {
            detail = nil
        }
        guard let detail, detail.expectedUsedPercent.isFinite, window.usedPercent.isFinite else { return nil }
        let expected = detail.expectedUsedPercent
        return PaceBits(
            left: detail.leftLabel,
            right: detail.rightLabel,
            pacePercent: detail.stage == .onTrack ? nil : expected,
            paceOnTop: window.usedPercent <= detail.expectedUsedPercent)
    }
}

struct ProviderSwitcherRepresentable: NSViewRepresentable {
    let providers: [UsageProvider]
    let selected: ProviderSwitcherSelection
    let width: CGFloat
    let weeklyRemaining: (UsageProvider) -> Double?
    let onSelect: (ProviderSwitcherSelection) -> Void

    func makeNSView(context: Context) -> ProviderSwitcherView {
        ProviderSwitcherView(
            providers: self.providers,
            selected: self.selected,
            includesOverview: true,
            width: self.width,
            showsIcons: true,
            iconProvider: { provider in
                ProviderBrandIcon.image(for: provider) ?? NSImage()
            },
            weeklyRemainingProvider: self.weeklyRemaining,
            onSelect: self.onSelect)
    }

    func updateNSView(_ view: ProviderSwitcherView, context: Context) {
        view.updateSelection(self.selected)
    }
}

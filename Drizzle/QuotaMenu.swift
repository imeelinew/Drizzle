import AppKit
import SwiftUI

struct ProviderQuotaCard: View {
    let provider: UsageProvider
    let windows: [RateWindow]
    let windowTitles: [String]
    let plan: String?
    let message: String?
    let updatedAt: Date?
    let balance: String?

    private var metadata: ProviderMetadata {
        ProviderDescriptorRegistry.descriptor(for: self.provider).metadata
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UsageMenuCardLayout.headerContentSpacing) {
            self.header
            if self.message != nil || !self.metrics.isEmpty || self.balance != nil {
                Divider()
            }
            if let balance {
                HStack {
                    Text("余额")
                    Spacer()
                    Text(balance).monospacedDigit()
                }
                .font(.footnote)
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
            let title = self.windowTitles.indices.contains(index)
                ? L(self.windowTitles[index])
                : index == 0 ? L(self.metadata.sessionLabel) : L(self.metadata.weeklyLabel)
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

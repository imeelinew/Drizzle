import SwiftUI

struct UsageMenuCardView {
    struct Model {
        enum PercentStyle: String {
            case left
            case used

            var labelSuffix: String {
                switch self {
                case .left: L("usage_percent_suffix_left")
                case .used: L("usage_percent_suffix_used")
                }
            }

            var accessibilityLabel: String {
                switch self {
                case .left: L("Usage remaining")
                case .used: L("Usage used")
                }
            }
        }

struct Metric: Identifiable {
    struct LinePresentation: Equatable {
        let titleText: String
        let resetText: String?
        let metaText: String?
    }

    let id: String
    let title: String
    let percent: Double
    let percentStyle: PercentStyle
    let statusText: String?
    let resetText: String?
    let detailText: String?
    let detailLeftText: String?
    let detailRightText: String?
    let pacePercent: Double?
    /// True when detailLeftText/detailRightText came from a pace forecast.
    let detailIsPaceDerived: Bool
    let paceOnTop: Bool
    let warningMarkerPercents: [Double]
    let workdayMarkerPercents: [Double]
    let workdayTickAppearance: WorkdayTickAppearance
    let cardStyle: Bool
    let sessionEquivalentDetail: UsagePaceText.SessionEquivalentDetail?

    init(
        id: String,
        title: String,
        percent: Double,
        percentStyle: PercentStyle,
        statusText: String? = nil,
        resetText: String?,
        detailText: String?,
        detailLeftText: String?,
        detailRightText: String?,
        pacePercent: Double?,
        detailIsPaceDerived: Bool = false,
        paceOnTop: Bool,
        warningMarkerPercents: [Double] = [],
        workdayMarkerPercents: [Double] = [],
        workdayTickAppearance: WorkdayTickAppearance = .subtle,
        cardStyle: Bool = false,
        sessionEquivalentDetail: UsagePaceText.SessionEquivalentDetail? = nil)
    {
        self.id = id
        self.title = title
        self.percent = percent
        self.percentStyle = percentStyle
        self.statusText = statusText
        self.resetText = resetText
        self.detailText = detailText
        self.detailLeftText = detailLeftText
        self.detailRightText = detailRightText
        self.pacePercent = pacePercent
        self.detailIsPaceDerived = detailIsPaceDerived
        self.paceOnTop = paceOnTop
        self.warningMarkerPercents = warningMarkerPercents
        self.workdayMarkerPercents = workdayMarkerPercents
        self.workdayTickAppearance = workdayTickAppearance
        self.cardStyle = cardStyle
        self.sessionEquivalentDetail = sessionEquivalentDetail
    }

    var percentLabel: String {
        UsageFormatter.percentText(self.percent, suffix: self.percentStyle.labelSuffix)
    }

    func linePresentation(title: String) -> LinePresentation {
        // Keep the title aligned with the configured used/remaining label semantics.
        let metaParts = [
            self.detailLeftText,
            self.detailRightText,
            self.sessionEquivalentDetail?.leftText,
            self.sessionEquivalentDetail?.rightText,
        ].compactMap { text -> String? in
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return text
        }
        return LinePresentation(
            titleText: "\(title) \(self.percentLabel)",
            resetText: self.resetText,
            metaText: metaParts.isEmpty ? nil : metaParts.joined(separator: " · "))
    }
}
    }

    static func popupMetricTitle(provider: UsageProvider, metric: Model.Metric) -> String {
        if provider == .openrouter, metric.id == "primary" {
            return L("API key limit")
        }
        return metric.title
    }
}

struct MetricRowHeader: View {
    let title: String
    let layoutTitle: String
    let resetText: String?
    let layoutResetText: String?
    let isHighlighted: Bool

    var body: some View {
        if let layoutResetText {
            let resolvedResetText = self.resetText ?? layoutResetText
            ViewThatFits(in: .horizontal) {
                self.layoutPreservingHeader(
                    layout: self.horizontalHeader(title: self.layoutTitle, resetText: layoutResetText),
                    content: self.horizontalHeader(title: self.title, resetText: resolvedResetText))
                self.layoutPreservingHeader(
                    layout: self.verticalHeader(title: self.layoutTitle, resetText: layoutResetText),
                    content: self.verticalHeader(title: self.title, resetText: resolvedResetText))
            }
        } else {
            self.titleLabel(self.title)
        }
    }

    private func horizontalHeader(title: String, resetText: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            self.titleLabel(title)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            self.resetLabel(resetText)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verticalHeader(title: String, resetText: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            self.titleLabel(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            self.resetLabel(resetText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func titleLabel(_ title: String) -> some View {
        Text(title)
            .font(.body)
            .fontWeight(.medium)
            .lineLimit(1)
    }

    private func resetLabel(_ resetText: String) -> some View {
        Text(resetText)
            .font(.footnote)
            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
    }

    private func layoutPreservingHeader(
        layout: some View,
        content: some View) -> some View
    {
        layout
            .hidden()
            .overlay(alignment: .topLeading) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .clipped()
    }
}

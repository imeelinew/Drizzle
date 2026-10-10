import Foundation

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

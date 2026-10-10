import AppKit

/// One lightweight drawing view replaces a hosting view and its entire rendering graph.
final class ProviderQuotaCard: NSView {
    private struct TextLine {
        let text: String
        let rect: NSRect
        let font: NSFont
        let color: NSColor
        let alignment: NSTextAlignment
        let wraps: Bool
    }

    private struct Bar {
        let rect: NSRect
        let percent: Double
        let pacePercent: Double?
        let paceOnTop: Bool
    }

    private let provider: UsageProvider
    private let windows: [RateWindow]
    private let windowTitles: [String]
    private var lines: [TextLine] = []
    private var bars: [Bar] = []
    private var divider: NSRect?
    private var accessibilityText: [String] = []
    private let footnote = NSFont.systemFont(ofSize: 11)
    private let bodyFont = NSFont.systemFont(ofSize: 13, weight: .medium)

    override var isFlipped: Bool { true }

    private var metadata: ProviderMetadata {
        ProviderDescriptorRegistry.descriptor(for: self.provider).metadata
    }

    init(
        provider: UsageProvider,
        windows: [RateWindow],
        windowTitles: [String],
        plan: String?,
        message: String?,
        updatedAt: Date?,
        balance: String?,
        balanceDetail: String?)
    {
        self.provider = provider
        self.windows = windows
        self.windowTitles = windowTitles
        super.init(frame: NSRect(x: 0, y: 0, width: 310, height: 1))
        let x = UsageMenuCardLayout.horizontalPadding
        let width = self.bounds.width - x * 2
        var y = UsageMenuCardLayout.headerOnlyVerticalPadding
        y += self.addText(self.metadata.displayName, x: x, y: y, width: width,
                          font: .systemFont(ofSize: 13, weight: .semibold))
        y += UsageMenuCardLayout.headerLineSpacing
        let subtitle = updatedAt.map { UsageFormatter.updatedString(from: $0) } ?? L("Updated just now")
        let planFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let planWidth = plan.map { min(width * 0.55, self.textWidth($0, font: planFont)) } ?? 0
        let subtitleWidth = planWidth > 0 ? width - planWidth - UsageMenuCardLayout.headerColumnSpacing : width
        let subtitleHeight = self.addText(subtitle, x: x, y: y, width: subtitleWidth,
                                         font: self.footnote, color: .secondaryLabelColor)
        if let plan, !plan.isEmpty {
            _ = self.addText(plan, x: x + width - planWidth, y: y, width: planWidth,
                             font: planFont, color: .controlAccentColor, alignment: .right)
        }
        y += subtitleHeight
        let metrics = self.metrics
        if message != nil || !metrics.isEmpty || balance != nil {
            y += UsageMenuCardLayout.headerContentSpacing
            self.divider = NSRect(x: x, y: y, width: width, height: 1)
            y += 1 + UsageMenuCardLayout.headerContentSpacing
        }
        if let balance {
            let height = self.addText("余额", x: x, y: y, width: width / 2, font: self.footnote)
            _ = self.addText(balance, x: x + width / 2, y: y, width: width / 2,
                             font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), alignment: .right)
            y += height
            if let balanceDetail {
                y += UsageMenuCardLayout.headerContentSpacing
                y += self.addText(balanceDetail, x: x, y: y, width: width,
                                  font: self.footnote, color: .secondaryLabelColor, wraps: true)
            }
        }
        if let message, metrics.isEmpty {
            y += UsageMenuCardLayout.usageSectionTopPadding
            y += self.addText(message, x: x, y: y, width: width, font: self.footnote,
                              color: .systemRed, wraps: true)
        }
        if !metrics.isEmpty {
            if balance != nil { y += UsageMenuCardLayout.headerContentSpacing }
            y += UsageMenuCardLayout.usageSectionTopPadding
            for (index, metric) in metrics.enumerated() {
                if index > 0 { y += 12 }
                let title = UsageMenuCardView.popupMetricTitle(provider: provider, metric: metric)
                let presentation = metric.linePresentation(title: title)
                let titleWidth = self.textWidth(presentation.titleText, font: self.bodyFont)
                if let reset = presentation.resetText {
                    let resetWidth = self.textWidth(reset, font: self.footnote)
                    if titleWidth + resetWidth + 16 <= width {
                        let height = self.addText(presentation.titleText, x: x, y: y, width: width - resetWidth - 16,
                                                  font: self.bodyFont)
                        _ = self.addText(reset, x: x + width - resetWidth, y: y + 1,
                                         width: resetWidth, font: self.footnote,
                                         color: .secondaryLabelColor, alignment: .right)
                        y += height
                    } else {
                        y += self.addText(presentation.titleText, x: x, y: y, width: width, font: self.bodyFont)
                        y += 2
                        y += self.addText(reset, x: x, y: y, width: width, font: self.footnote,
                                          color: .secondaryLabelColor, alignment: .right, wraps: true, maxLines: 2)
                    }
                } else {
                    y += self.addText(presentation.titleText, x: x, y: y, width: width, font: self.bodyFont)
                }
                y += 6
                self.bars.append(Bar(rect: NSRect(x: x, y: y, width: width, height: 6),
                                     percent: metric.percent, pacePercent: metric.pacePercent, paceOnTop: metric.paceOnTop))
                y += 6
                if let meta = presentation.metaText {
                    y += 6
                    y += self.addText(meta, x: x, y: y, width: width, font: self.footnote,
                                      color: .secondaryLabelColor, wraps: true, maxLines: 2)
                }
            }
        }
        self.frame.size.height = ceil(y + UsageMenuCardLayout.sectionBottomPadding)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.staticText)
        self.setAccessibilityLabel(self.accessibilityText.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for line in self.lines where line.rect.intersects(dirtyRect) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = line.alignment
            paragraph.lineBreakMode = line.wraps ? .byWordWrapping : .byTruncatingTail
            (line.text as NSString).draw(with: line.rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: [.font: line.font, .foregroundColor: line.color, .paragraphStyle: paragraph])
        }
        if let divider {
            NSColor.separatorColor.setFill()
            divider.fill()
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = max(1, self.window?.backingScaleFactor ?? 2)
        for bar in self.bars where bar.rect.intersects(dirtyRect) {
            context.saveGState()
            context.clip(to: bar.rect)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let rect = bar.rect
            let radius = rect.height / 2
            context.setFillColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.22).cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            let percent = min(100, max(0, bar.percent))
            let displayed = Int(percent.rounded())
            let fillPercent = displayed == 0 ? 0 : displayed == 100 ? 100 : percent
            if fillPercent > 0 {
                let fill = NSRect(x: rect.minX, y: rect.minY, width: rect.width * fillPercent / 100, height: rect.height)
                context.setFillColor(self.metadata.color.nsColor.cgColor)
                context.addPath(CGPath(roundedRect: fill, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
            if let pace = bar.pacePercent {
                let position = rect.minX + rect.width * min(100, max(0, pace)) / 100
                let center = (position * scale).rounded() / scale
                context.setBlendMode(.destinationOut)
                context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                context.fill(NSRect(x: center - 3, y: rect.minY, width: 6, height: rect.height))
                context.setBlendMode(.normal)
                context.setFillColor((bar.paceOnTop ? NSColor.systemGreen : .systemRed).cgColor)
                context.fill(NSRect(x: center - 1, y: rect.minY, width: 2, height: rect.height))
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    @discardableResult
    private func addText(
        _ text: String, x: CGFloat, y: CGFloat, width: CGFloat, font: NSFont,
        color: NSColor = .labelColor, alignment: NSTextAlignment = .left,
        wraps: Bool = false, maxLines: Int? = nil) -> CGFloat
    {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let measured = wraps ? ceil((text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin,
            attributes: [.font: font]).height) : lineHeight
        let height = max(lineHeight, min(measured, maxLines.map { lineHeight * CGFloat($0) } ?? measured))
        self.lines.append(TextLine(text: text, rect: NSRect(x: x, y: y, width: width, height: height),
                                   font: font, color: color, alignment: alignment, wraps: wraps))
        self.accessibilityText.append(text)
        return height
    }

    private var metrics: [UsageMenuCardView.Model.Metric] {
        self.windows.enumerated().map { index, window in
            let title = self.windowTitles.indices.contains(index)
                ? L(self.windowTitles[index])
                : index == 0 ? L(self.metadata.sessionLabel) : L(self.metadata.weeklyLabel)
            let pace = Self.paceDetail(provider: self.provider, window: window, isSession: index == 0)
            return UsageMenuCardView.Model.Metric(
                id: self.windowTitles.indices.contains(index)
                    ? self.windowTitles[index]
                    : index == 0 ? "primary" : index == 1 ? "secondary" : "tertiary",
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

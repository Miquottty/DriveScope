import SwiftUI

/// HUD readout: small tracked label over a monospaced value with a trailing unit (ALT / COURSE / DIST / G).
/// Labels are English abbreviations in every language (PLAN §13), hence verbatim text.
struct TelemetryValue: View {
    struct Style {
        var valueSize: CGFloat
        var unitSize: CGFloat
        var unitGap: CGFloat = 3
        var labelSize: CGFloat = 11
        /// Label-to-value spacing.
        var spacing: CGFloat = 4
        var labelWeight = Font.Weight.regular
        var unitColor = Theme.textSecondary

        /// Phone HUD G readouts (portrait: side by side above the meter; landscape: stacked beside it).
        static let gForceStacked = Style(valueSize: 40, unitSize: 16, unitGap: 4, labelSize: 12, spacing: 2)
        /// Phone HUD metric row, label left of the value (`InlineTelemetryValue`).
        static let metricInline = Style(valueSize: 24, unitSize: 13, labelSize: 11, spacing: 6)

        // iPad (mock artboards 12 / 16): semibold 15 pt labels, units in the lighter secondary color.
        /// ALT / COURSE / DIST tiles.
        static let padTile = Style(valueSize: 56, unitSize: 22, unitGap: 6, labelSize: 15, spacing: 4,
                                   labelWeight: .semibold, unitColor: Theme.textTertiary)
        /// LATERAL / LONG next to the meter.
        static let padGForce = Style(valueSize: 48, unitSize: 20, unitGap: 4, labelSize: 15, spacing: 0,
                                     labelWeight: .semibold, unitColor: Theme.textTertiary)
    }

    var label: String
    var value: String
    var unit: String?
    var style: Style
    var valueColor: Color = Theme.textPrimary
    var alignment: HorizontalAlignment = .center

    var body: some View {
        VStack(alignment: alignment, spacing: style.spacing) {
            Text(verbatim: label)
                .font(.system(size: style.labelSize, weight: style.labelWeight))
                .tracking(style.labelSize * 0.1)
                .foregroundStyle(Theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: style.unitGap) {
                Text(verbatim: value)
                    .font(.hudNumber(size: style.valueSize, weight: .medium))
                    .foregroundStyle(valueColor)
                if let unit {
                    Text(verbatim: unit)
                        .font(.hudNumber(size: style.unitSize))
                        .foregroundStyle(style.unitColor)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A `TelemetryValue` on one line: the label sits left of the value on its baseline (the phone HUD's ALT / COURSE / DIST row).
struct InlineTelemetryValue: View {
    var label: String
    var value: String
    var unit: String?
    var style = TelemetryValue.Style.metricInline

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: style.spacing) {
            Text(verbatim: label)
                .font(.system(size: style.labelSize, weight: style.labelWeight))
                .tracking(style.labelSize * 0.1)
                .foregroundStyle(Theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: style.unitGap) {
                Text(verbatim: value)
                    .font(.hudNumber(size: style.valueSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                if let unit {
                    Text(verbatim: unit)
                        .font(.hudNumber(size: style.unitSize))
                        .foregroundStyle(style.unitColor)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }
}

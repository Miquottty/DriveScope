import DriveDomain
import DriveStorage
import SwiftUI

// Building blocks of the iPad Session Detail (mock 13). Type scale per design/mock/README.md "iPad の視認性ルール".

/// Icon + title inside a 52 pt action button (Replay / Export).
struct IPadActionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
            Text(title)
                .font(.system(size: 16, weight: .semibold))
        }
        .padding(.horizontal, 18)
        .frame(minHeight: IPadMetrics.minTouch)
    }
}

/// TIME / DISTANCE / MAX over AVG / GAIN / PEAK G, 30 pt mono values.
struct IPadMetricsGrid: View {
    let session: DriveSession
    let format: SessionFormat

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        LazyVGrid(columns: columns, spacing: 12) {
            IPadMetricTile(label: "Time", value: format.duration(session.duration))
            IPadMetricTile(label: "Distance", quantity: format.distance(meters: session.distance))
            IPadMetricTile(label: "Max", quantity: format.speed(metersPerSecond: session.maxSpeed))
            IPadMetricTile(label: "Avg", quantity: format.speed(metersPerSecond: session.avgSpeed))
            IPadMetricTile(label: "Gain", quantity: format.elevationGain(meters: session.elevationGain))
            IPadMetricTile(label: "Peak G", value: format.number(session.peakLateralG, fraction: 2), tint: Theme.accent)
        }
    }
}

private struct IPadMetricTile: View {
    let label: LocalizedStringKey
    let value: String
    var unit = ""
    var tint = Theme.textPrimary

    init(label: LocalizedStringKey, value: String, tint: Color = Theme.textPrimary) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    init(label: LocalizedStringKey, quantity: Quantity) {
        self.label = label
        value = quantity.value
        unit = quantity.unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).iPadLabel()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: value)
                    .font(.hudNumber(size: 30, weight: .medium))
                    .foregroundStyle(tint)
                if !unit.isEmpty {
                    Text(verbatim: unit)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .minimumScaleFactor(0.7)
        }
        .lineLimit(1)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: IPadMetrics.tileRadius))
        .accessibilityElement(children: .combine)
    }
}

/// GPS accuracy, the longest fix gap and motion drop in a 2×2 grid. Telemetry terms stay English in both languages.
struct IPadLogQualityCard: View {
    let session: DriveSession
    let format: SessionFormat

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: 16, alignment: .leading), GridItem(.flexible(), alignment: .leading)]
        let motion = session.motionSampleCount > 0 ? "Motion drop \(format.percent(session.motionDropRate))" : "Motion —"
        VStack(alignment: .leading, spacing: 10) {
            Text("Log Quality").iPadLabel()
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                Text(verbatim: "GPS P50 \(format.meters(session.gpsAccuracyP50).text)")
                Text(verbatim: "P95 \(format.meters(session.gpsAccuracyP95).text)")
                Text(verbatim: "Max gap \(format.seconds(session.maxLocationGap).text)")
                Text(verbatim: motion)
            }
            .font(.hudNumber(size: 15))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .iPadCard(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .accessibilityElement(children: .combine)
    }
}

/// "START 14:05" / "END 14:48" plates over the bottom of the iPad map.
struct RouteEndpointChips: View {
    let session: DriveSession
    @Environment(AppLanguage.self) private var appLanguage

    var body: some View {
        let format = SessionFormat(language: appLanguage)
        let zone = TimeZone(identifier: session.timeZoneID) ?? .current
        HStack(spacing: 8) {
            chip("START \(format.clockTime(session.startedAt, in: zone))", tint: Theme.good)
            if let end = session.endedAt {
                chip("END \(format.clockTime(end, in: zone))", tint: Theme.rec)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(verbatim: text)
            .font(.hudNumber(size: 14))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

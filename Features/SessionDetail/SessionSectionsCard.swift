import DriveDomain
import SwiftUI

/// Section analysis summary (V1.1): corners left / right with the hardest one, total climb and descent with the
/// steepest grade, stops with their total time. Hidden until the session has sections.
struct SessionSectionsCard: View {
    let sections: [DriveSection]
    /// iPad (mock 13 card style).
    var large = false

    private struct Row: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let value: String
        let color: Color
    }

    private var rows: [Row] {
        var rows: [Row] = []
        let corners = sections.filter { $0.kind == .corner }
        if !corners.isEmpty {
            let left = corners.filter { $0.direction == .left }.count
            let peak = corners.compactMap(\.peakLateralG).max() ?? 0
            rows.append(Row(
                id: "corner", label: "Corners",
                value: "L \(left) · R \(corners.count - left) · " + String(format: "%.2f G", peak), color: Theme.accent
            ))
        }
        for (kind, label, color) in [(DriveSection.Kind.climb, "Climbs" as LocalizedStringKey, Theme.good), (.descent, "Descents", Theme.textTertiary)] {
            let runs = sections.filter { $0.kind == kind }
            guard !runs.isEmpty else { continue }
            let total = runs.compactMap(\.altitudeChange).reduce(0, +)
            let steepest = runs.compactMap { $0.averageGrade.map(abs) }.max() ?? 0
            rows.append(Row(
                id: kind.rawValue, label: label,
                value: Self.signedMeters(total) + String(format: " m · %.0f %%", steepest * 100), color: color
            ))
        }
        let stops = sections.filter { $0.kind == .stop }
        if !stops.isEmpty {
            let total = Int(stops.map(\.duration).reduce(0, +).rounded())
            rows.append(Row(
                id: "stop", label: "Stops",
                value: "\(stops.count) · " + String(format: "%d:%02d", total / 60, total % 60), color: Theme.textSecondary
            ))
        }
        return rows
    }

    /// "+1,226" — grouped like the metrics grid above (digits stay Latin in both languages).
    private static func signedMeters(_ value: Double) -> String {
        (value < 0 ? "−" : "+") + Int(abs(value).rounded()).formatted(.number.locale(Locale(identifier: "en_US")))
    }

    var body: some View {
        let rows = rows
        if large, !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sections").iPadLabel()
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(row.label)
                                .foregroundStyle(Theme.textTertiary)
                            Spacer(minLength: 0)
                            Text(verbatim: row.value)
                                .font(.hudNumber(size: 16))
                                .foregroundStyle(row.color)
                        }
                        .font(.system(size: 16))
                    }
                }
            }
            .iPadCard(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
            .accessibilityElement(children: .combine)
        } else if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sections")
                    .font(.system(size: 10))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.textSecondary)
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 84, alignment: .leading)
                        Text(verbatim: row.value)
                            .font(.hudNumber(size: 13))
                            .foregroundStyle(row.color)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
        }
    }
}

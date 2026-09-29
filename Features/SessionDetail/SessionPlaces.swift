import DriveDomain
import DriveStorage
import SwiftUI

/// "前橋市 → 渋川市" under the title, plus the offline note while reverse geocoding is still pending (PLAN §8).
struct SessionPlacesLine: View {
    let session: DriveSession
    /// The displayed title; the line is dropped when the title already names these places.
    let title: String

    var body: some View {
        let names = Self.names(start: session.startPlace, end: session.endPlace)
        let line = Self.line(names)
        let showsLine = line != nil && !names.allSatisfy(title.contains)
        if showsLine || session.geocodePending {
            VStack(alignment: .leading, spacing: 3) {
                if let line, showsLine {
                    Label {
                        Text(verbatim: line)
                    } icon: {
                        Image(systemName: "mappin.and.ellipse")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                }
                if session.geocodePending {
                    Label("Place names pending (offline)", systemImage: "wifi.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    private static func names(start: PlaceMeta?, end: PlaceMeta?) -> [String] {
        [start?.shortName, end?.shortName].compactMap { $0 }
    }

    private static func line(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        return names.count == 2 && names[0] != names[1] ? "\(names[0]) → \(names[1])" : first
    }
}

/// Highest point / peak G / via places, one compact line each. Hidden when none has a name.
struct SessionPlacesCard: View {
    let places: [PlaceMeta]

    var body: some View {
        let rows = places.enumerated().compactMap { index, place in
            (place.name ?? place.locality ?? place.shortName).map { Row(id: index, role: place.role, name: $0) }
        }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Places")
                    .font(.system(size: 10))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.textSecondary)
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.role.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 84, alignment: .leading)
                        Text(verbatim: row.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
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

    private struct Row: Identifiable {
        var id: Int
        var role: PlaceRole
        var name: String
    }
}

private extension PlaceRole {
    var label: LocalizedStringKey {
        switch self {
        case .maxAltitude: "Highest point"
        case .peakG: "Peak G"
        case .start, .end, .via: "Via"
        }
    }
}

import DriveDomain
import SwiftUI

/// Chip text and colors for sections (V1.1). Chip text is HUD shorthand, English in both languages like the other
/// telemetry labels (PLAN §13); VoiceOver gets a localized description.
enum SectionFormat {
    /// "L 0.32G", "STOP 20s", "↑ 120m 6%", "↓ 80m 5%".
    static func chip(_ section: DriveSection) -> String {
        switch section.kind {
        case .corner:
            let side = section.direction == .left ? "L" : "R"
            return "\(side) " + String(format: "%.2fG", section.peakLateralG ?? 0)
        case .stop:
            return "STOP \(Int(section.duration.rounded()))s"
        case .climb, .descent:
            let arrow = section.kind == .climb ? "↑" : "↓"
            let grade = Int((abs(section.averageGrade ?? 0) * 100).rounded())
            return "\(arrow) \(Int(abs(section.altitudeChange ?? 0).rounded()))m \(grade)%"
        }
    }

    static func color(_ section: DriveSection) -> Color {
        switch section.kind {
        case .corner: Theme.accent
        case .stop: Theme.textSecondary
        case .climb: Theme.good
        case .descent: Theme.textTertiary
        }
    }

    static func label(_ section: DriveSection) -> Text {
        switch section.kind {
        case .corner: section.direction == .left ? Text("Left corner") : Text("Right corner")
        case .stop: Text("Stop")
        case .climb: Text("Climb")
        case .descent: Text("Descent")
        }
    }
}

/// The session's sections as chips under the timeline; tapping one plays from just before it. The chip the
/// playhead is in is highlighted. `includesMarkers` puts the marker chips first on the same row (iPhone).
struct ReplaySectionStrip: View {
    let player: ReplayPlayer
    var includesMarkers = false

    var body: some View {
        let sections = player.timeline?.sections ?? []
        let markers = includesMarkers ? player.timeline?.markers ?? [] : []
        if !sections.isEmpty || !markers.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(markers) { marker in
                            MarkerChip(marker: marker) { player.seek(to: marker.elapsed) }
                        }
                        ForEach(sections) { section in
                            chip(section, active: section.start <= player.time && player.time <= section.end)
                                .id(section.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onChange(of: activeID(in: sections)) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func activeID(in sections: [DriveSection]) -> String? {
        sections.last { $0.start <= player.time && player.time <= $0.end }?.id
    }

    private func chip(_ section: DriveSection, active: Bool) -> some View {
        Button {
            player.seek(to: max(0, section.start - 1))
        } label: {
            Text(verbatim: SectionFormat.chip(section))
                .font(.hudNumber(size: 11))
                .foregroundStyle(SectionFormat.color(section))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(active ? Theme.dividerStrong : Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(HUDButtonStyle())
        .accessibilityLabel(SectionFormat.label(section))
        .accessibilityValue(Text(verbatim: SectionFormat.chip(section)))
        .accessibilityHint(Text("Jumps to this section"))
    }
}

struct MarkerChip: View {
    let marker: ReplayTimeline.Marker
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: ReplayFormat.markerChip(kind: marker.kind, elapsed: marker.elapsed))
                .font(.hudNumber(size: 11))
                .foregroundStyle(marker.kind.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(HUDButtonStyle())
        .accessibilityHint(Text("Jumps to this marker"))
    }
}

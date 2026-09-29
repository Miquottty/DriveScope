import SwiftUI

/// Design tokens from design/mock/README.md. Never use literal colors in views.
enum Theme {
    static let background = Color(hex: 0x0B0D10)
    /// Recording / StandBy backgrounds are true black.
    static let hudBackground = Color(hex: 0x000000)
    static let surface = Color(hex: 0x14181D)
    static let divider = Color(hex: 0x1F252C)
    static let dividerStrong = Color(hex: 0x2A323B)

    static let textPrimary = Color(hex: 0xE8ECF0)
    static let textSecondary = Color(hex: 0x8A94A0)
    /// The lighter of the two secondary text colors.
    static let textTertiary = Color(hex: 0xB4BEC8)
    static let textMuted = Color(hex: 0x5C6670)

    static let accent = Color(hex: 0xF2A33A)
    static let rec = Color(hex: 0xE5484D)
    static let good = Color(hex: 0x7BD88F)

    // iPad (mock 11–16).
    /// Sidebar, sensor tiles and unselected preset pills.
    static let panel = Color(hex: 0x0F1216)
    /// Selected preset pill.
    static let accentFill = Color(hex: 0x2A1F0E)
    /// The ring around the iPad START button.
    static let accentHalo = Color(hex: 0x221A0D)
}

/// iPad spacing (design/mock/README.md "iPad の視認性ルール"). iPad text never uses `Theme.textMuted`.
enum IPadMetrics {
    static let margin: CGFloat = 32
    static let cardRadius: CGFloat = 16
    static let cardPadding: CGFloat = 20
    static let gap: CGFloat = 20
    static let tileRadius: CGFloat = 14
    static let minTouch: CGFloat = 52
}

extension View {
    /// Phone layouts are designed at ~390 pt; on iPad / wide windows, cap the content and center it.
    func readableWidth(_ width: CGFloat = 640) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }

    /// iPad card: surface, radius 16, padding 20. `fillHeight` stretches it to the height its container offers.
    func iPadCard(
        padding: EdgeInsets = EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20), fillHeight: Bool = false
    ) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: IPadMetrics.cardRadius))
    }

    /// Pointer / Pencil hover highlight shaped like the tappable card.
    func cardHoverEffect(cornerRadius: CGFloat = IPadMetrics.cardRadius) -> some View {
        contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius)).hoverEffect(.highlight)
    }

    /// A sheet presented from an iPad layout: form-sized, with the iPad type scale inside.
    func iPadFormSheet() -> some View {
        presentationSizing(.form).environment(\.iPadSheet, true)
    }
}

extension Text {
    /// iPad section and tile label: 13 pt semibold caps, 0.1 em tracking.
    func iPadLabel() -> some View {
        font(.system(size: 13, weight: .semibold))
            .tracking(1.3)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textSecondary)
    }
}

extension EnvironmentValues {
    /// Set on sheets presented from the iPad layouts. A form sheet on iPad can report a compact size class, yet its
    /// content should still follow the iPad readability rules.
    @Entry var iPadSheet = false
}

extension Font {
    /// Numbers are monospaced everywhere (SF Mono look).
    static func hudNumber(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - iPad Recording HUD / Timeline Replay (mock artboards 12, 14, 16)

extension Theme {
    /// Round transport buttons and MARK chips on the iPad Replay bar (mock `#1B2026`).
    static let replayControl = Color(hex: 0x1B2026)
    /// SYNC chip fill on the iPad Replay bar: a dark tint of `good` (mock `#10261A`).
    static let syncChipFill = Color(hex: 0x10261A)
}

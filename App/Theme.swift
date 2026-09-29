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
}

extension View {
    /// Phone layouts are designed at ~390 pt; on iPad / wide windows, cap the content and center it.
    func readableWidth(_ width: CGFloat = 640) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }
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

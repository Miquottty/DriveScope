import DriveDomain
import SwiftUI

extension MarkerKind {
    /// The HUD button titles, English in both languages (PLAN §13).
    var title: String {
        switch self {
        case .mark: "MARK"
        case .sync: "SYNC"
        case .highlight: "HIGHLIGHT"
        }
    }

    /// Pins, chips and timeline rules on Session Detail and Replay: SYNC green, HIGHLIGHT amber, MARK white.
    var color: Color {
        switch self {
        case .mark: Theme.textPrimary
        case .sync: Theme.good
        case .highlight: Theme.accent
        }
    }

    /// iPad Replay chip fill (mock artboard 14): a dark tint of `color`.
    var chipFill: Color {
        switch self {
        case .mark: Theme.replayControl
        case .sync: Theme.syncChipFill
        case .highlight: Theme.accentFill
        }
    }
}

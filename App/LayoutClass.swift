import SwiftUI

enum LayoutClass {
    /// An iPad-sized window: regular in both directions. A Plus / Max iPhone in landscape is regular × compact and
    /// keeps the iPhone layouts (tabs, phone Home / HUD / Replay), like every other iPhone.
    static func isPad(_ horizontal: UserInterfaceSizeClass?, _ vertical: UserInterfaceSizeClass?) -> Bool {
        horizontal == .regular && vertical == .regular
    }
}

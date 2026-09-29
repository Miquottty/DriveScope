import Foundation
import Observation

/// Navigation state of the Sessions tab, owned by `RootTabView` so that Home and the recorder can push a detail.
@Observable
final class SessionsNavigation {
    var path: [UUID] = []
}

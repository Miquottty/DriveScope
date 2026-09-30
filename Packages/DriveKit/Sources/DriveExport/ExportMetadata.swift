import DriveDomain
import Foundation

/// A SYNC / MARK / HIGHLIGHT marker as exported (PLAN §3: elapsed and absolute time both kept).
public struct ExportMarker: Sendable, Equatable {
    public var kind: MarkerKind
    /// Seconds since session start.
    public var elapsed: TimeInterval
    public var date: Date
    public var label: String?

    public init(kind: MarkerKind, elapsed: TimeInterval, date: Date, label: String? = nil) {
        self.kind = kind
        self.elapsed = elapsed
        self.date = date
        self.label = label
    }
}

/// Session facts that live in SwiftData rather than in the `.bin` files. The app builds this on the
/// main actor from `DriveSession` and hands the Sendable copy to the exporters.
public struct ExportMetadata: Sendable, Equatable {
    public var title: String
    public var notes: String
    public var places: [PlaceMeta]
    public var markers: [ExportMarker]
    public var summary: SessionSummary
    /// Corners, climbs / descents and stops (derived, PLAN §12).
    public var sections: [DriveSection]

    public init(
        title: String = "", notes: String = "", places: [PlaceMeta] = [], markers: [ExportMarker] = [],
        summary: SessionSummary = SessionSummary(), sections: [DriveSection] = []
    ) {
        self.title = title
        self.notes = notes
        self.places = places
        self.markers = markers
        self.summary = summary
        self.sections = sections
    }

    /// Session elapsed of the earliest SYNC marker: t = 0 of the Vlog CSV.
    var syncElapsed: TimeInterval? {
        markers.filter { $0.kind == .sync }.map(\.elapsed).min()
    }
}

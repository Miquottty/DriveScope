import DriveDomain
import Foundation
import SwiftData

/// Thin wrapper over the SwiftData metadata store (PLAN §4.2). Main-actor: it owns the container's `mainContext`.
@MainActor
public final class SessionStore {
    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([DriveSession.self, Marker.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    public func create(manifest: SessionManifest) throws -> DriveSession {
        let session = DriveSession(manifest: manifest)
        context.insert(session)
        try context.save()
        return session
    }

    public func session(id: UUID) -> DriveSession? {
        var descriptor = FetchDescriptor<DriveSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Every session, newest first.
    public func allSessions() -> [DriveSession] {
        (try? context.fetch(FetchDescriptor<DriveSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))) ?? []
    }

    public func sessions(in state: RecordingState) -> [DriveSession] {
        // Compare the raw value: enum key paths in predicates are not reliably supported.
        let raw = state.rawValue
        let descriptor = FetchDescriptor<DriveSession>(
            predicate: #Predicate { $0.state.rawValue == raw },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    public func finish(
        _ session: DriveSession, state: RecordingState, endedAt: Date, summary: SessionSummary,
        routePreview: [RoutePoint]
    ) throws {
        session.state = state
        session.endedAt = endedAt
        session.summary = summary
        session.routePreview = routePreview
        try context.save()
    }

    @discardableResult
    public func addMarker(
        kind: MarkerKind, elapsed: TimeInterval, date: Date, label: String? = nil, to session: DriveSession
    ) throws -> Marker {
        let marker = Marker(kind: kind, elapsed: elapsed, date: date, label: label)
        context.insert(marker)
        marker.session = session
        try context.save()
        return marker
    }

    /// Removes the metadata and the session folder. A missing folder is not an error.
    public func delete(_ session: DriveSession, filesRoot: URL) throws {
        let files = SessionFiles(root: filesRoot, sessionID: session.id)
        context.delete(session)
        try context.save()
        do {
            try files.delete()
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // Already gone (e.g. a session that never wrote a sample).
        }
    }

    public func save() throws {
        try context.save()
    }

    /// Evenly downsamples fixes to at most `maxPoints`, always keeping the first and last usable fix.
    public static func routePreview(from locations: [LocationSample], maxPoints: Int = 200) -> [RoutePoint] {
        let usable = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 50 }
        guard maxPoints >= 2, usable.count > maxPoints else {
            return usable.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
        }
        let step = Double(usable.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { i in
            let s = usable[i == maxPoints - 1 ? usable.count - 1 : Int((Double(i) * step).rounded())]
            return RoutePoint(latitude: s.latitude, longitude: s.longitude)
        }
    }
}

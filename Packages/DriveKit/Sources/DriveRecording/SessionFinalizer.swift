import DriveDomain
import DriveReplay
import DriveStorage
import Foundation
import MapKit

/// Reverse geocoding behind a protocol so the finalizer is testable offline.
public protocol ReverseGeocoder: Sendable {
    func place(latitude: Double, longitude: Double, role: PlaceRole, locale: Locale) async throws -> PlaceMeta
}

/// `MKReverseGeocodingRequest` (iOS 26+; `CLGeocoder` is deprecated — PLAN §0).
public struct MapKitGeocoder: ReverseGeocoder {
    public init() {}

    public func place(latitude: Double, longitude: Double, role: PlaceRole, locale: Locale) async throws -> PlaceMeta {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)) else {
            throw CocoaError(.featureUnsupported)
        }
        request.preferredLocale = locale
        let item = try await request.mapItems.first
        let address = item?.addressRepresentations
        let fullAddress = address?.fullAddress(includingRegion: true, singleLine: true)
        // Without a POI, MapKit names the item by its street address; that is not a place name.
        let name = item?.name.flatMap { name in fullAddress?.contains(name) == true ? nil : name }
        return PlaceMeta(
            name: name,
            locality: address?.cityName,
            administrativeArea: address?.regionName,
            fullAddress: fullAddress,
            mapItemIdentifier: item?.identifier?.rawValue,
            latitude: latitude, longitude: longitude, role: role
        )
    }
}

/// STOP-time metadata (PLAN §8): places for the representative points and the automatic title.
/// Failures leave `geocodePending = true`; `retryPending()` runs again when the network is back.
@MainActor
public final class SessionFinalizer {
    private let store: SessionStore
    private let filesRoot: URL
    private let geocoder: any ReverseGeocoder
    private let locale: @MainActor () -> Locale
    private let loopWord: @MainActor () -> String

    public init(
        store: SessionStore, filesRoot: URL, geocoder: any ReverseGeocoder = MapKitGeocoder(),
        locale: @escaping @MainActor () -> Locale, loopWord: @escaping @MainActor () -> String
    ) {
        self.store = store
        self.filesRoot = filesRoot
        self.geocoder = geocoder
        self.locale = locale
        self.loopWord = loopWord
    }

    public func finalize(_ session: DriveSession) async {
        await ensureSections(session)
        let files = SessionFiles(root: filesRoot, sessionID: session.id)
        let clock = session.clock
        let candidates = await Self.candidates(files: files, clock: clock)
        guard !candidates.isEmpty else {
            session.geocodePending = false
            try? store.save()
            return
        }
        var places: [PlaceMeta] = []
        var failed = false
        let locale = locale()
        for candidate in candidates {
            do {
                places.append(try await geocoder.place(
                    latitude: candidate.latitude, longitude: candidate.longitude, role: candidate.role, locale: locale
                ))
            } catch {
                failed = true
                // Keep the coordinates so a retry (or the map) still has them.
                places.append(PlaceMeta(latitude: candidate.latitude, longitude: candidate.longitude, role: candidate.role))
            }
        }
        session.startPlace = places.first { $0.role == .start }
        session.endPlace = places.first { $0.role == .end }
        session.viaPlaces = places.filter { $0.role != .start && $0.role != .end }
        session.geocodePending = failed
        if !session.titleIsUserEdited, let title = SessionTitle.make(start: session.startPlace, end: session.endPlace, loopWord: loopWord()) {
            session.title = title
        }
        try? store.save()
    }

    /// Computes the sections when missing or made by an older detector (sessions recorded before V1.1 get them the
    /// first time Detail, Replay or Export needs them). Never for a session still recording.
    public func ensureSections(_ session: DriveSession) async {
        guard session.state != .recording, session.sectionsVersion < SectionDetector.version else { return }
        let files = SessionFiles(root: filesRoot, sessionID: session.id)
        guard let sections = await Self.detectSections(files: files, calibration: session.calibration) else { return }
        session.sections = sections
        session.sectionsVersion = SectionDetector.version
        try? store.save()
    }

    /// Sessions whose geocoding failed (offline at STOP).
    public func retryPending() async {
        for session in store.allSessions() where session.geocodePending && session.state != .recording {
            await finalize(session)
        }
    }

    /// nil when the files can't be read (then nothing is stored and a later call tries again).
    @concurrent nonisolated private static func detectSections(files: SessionFiles, calibration: MountCalibration?) async -> [DriveSection]? {
        guard let reader = try? TelemetryReader(files: files) else { return nil }
        return SectionDetector.detect(reader: reader, calibration: calibration)
    }

    @concurrent nonisolated private static func candidates(files: SessionFiles, clock: SessionClock) async -> [PlacePicker.Candidate] {
        PlacePicker.candidates(locations: (try? files.locations()) ?? [], clock: clock)
    }
}

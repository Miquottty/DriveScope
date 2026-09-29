import DriveDomain
import Foundation
import SwiftData

/// Session metadata (PLAN §4.2). Samples live in the binary files; this is the list / detail index.
@Model
public final class DriveSession {
    @Attribute(.unique) public var id: UUID
    public var startedAt: Date
    public var startUptime: TimeInterval
    public var endedAt: Date?
    public var timeZoneID: String
    /// "yyyy-MM" of `startedAt` in the session's own time zone; the `@Query(sectionBy:)` key for month grouping.
    /// The default lets existing stores migrate; rows created before this field exist keep "".
    public var monthSection: String = ""
    public var state: RecordingState
    public var preset: CapturePreset
    /// Set by the finalizer once places are known; empty until then.
    public var title: String
    public var titleIsUserEdited: Bool
    public var notes: String?
    public var appVersion: String
    public var deviceModel: String
    public var osVersion: String

    // Statistics (fixed at STOP, recomputed on recovery). Stored individually so lists can sort / filter on them.
    public var duration: TimeInterval
    public var distance: Double
    public var maxSpeed: Double
    public var avgSpeed: Double
    public var elevationGain: Double
    public var peakLateralG: Double
    public var gpsAccuracyP50: Double
    public var gpsAccuracyP95: Double
    public var maxLocationGap: TimeInterval
    public var locationSampleCount: Int
    public var motionSampleCount: Int
    public var motionDropRate: Double
    public var batteryUsagePerHour: Double?

    @Attribute(.codable) public var calibration: MountCalibration?
    @Attribute(.codable) public var startPlace: PlaceMeta?
    @Attribute(.codable) public var endPlace: PlaceMeta?
    @Attribute(.codable) public var viaPlaces: [PlaceMeta]
    /// Downsampled route (≤ 200 points) for list thumbnails, so lists never open the binary files.
    @Attribute(.codable) public var routePreview: [RoutePoint]
    public var geocodePending: Bool
    /// Corners, climbs / descents and stops (PLAN §12). Derived; recomputed when `sectionsVersion` is older than
    /// the detector's. The defaults let existing stores migrate.
    @Attribute(.codable) public var sections: [DriveSection] = []
    public var sectionsVersion: Int = 0
    /// When the streams were compressed (V1.1, LZFSE); nil while raw. The default lets existing stores migrate.
    public var archivedAt: Date? = nil

    @Relationship(deleteRule: .cascade, inverse: \Marker.session) public var markers: [Marker]

    public init(manifest: SessionManifest) {
        id = manifest.sessionID
        startedAt = manifest.clock.startedAt
        startUptime = manifest.clock.startUptime
        endedAt = nil
        timeZoneID = manifest.timeZoneID
        monthSection = Self.monthSection(for: manifest.clock.startedAt, timeZoneID: manifest.timeZoneID)
        state = .recording
        preset = manifest.preset
        title = ""
        titleIsUserEdited = false
        notes = nil
        appVersion = manifest.appVersion
        deviceModel = manifest.deviceModel
        osVersion = manifest.osVersion

        duration = 0
        distance = 0
        maxSpeed = 0
        avgSpeed = 0
        elevationGain = 0
        peakLateralG = 0
        gpsAccuracyP50 = 0
        gpsAccuracyP95 = 0
        maxLocationGap = 0
        locationSampleCount = 0
        motionSampleCount = 0
        motionDropRate = 0
        batteryUsagePerHour = nil

        calibration = nil
        startPlace = nil
        endPlace = nil
        viaPlaces = []
        routePreview = []
        geocodePending = false
        sections = []
        sectionsVersion = 0
        archivedAt = nil
        markers = []
    }

    private static func monthSection(for date: Date, timeZoneID: String) -> String {
        // Fixed POSIX formatting: the key must not depend on the user's locale or calendar.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    public var clock: SessionClock {
        get { SessionClock(startedAt: startedAt, startUptime: startUptime) }
        set {
            startedAt = newValue.startedAt
            startUptime = newValue.startUptime
        }
    }

    public var summary: SessionSummary {
        get {
            var s = SessionSummary()
            s.duration = duration
            s.distance = distance
            s.maxSpeed = maxSpeed
            s.avgSpeed = avgSpeed
            s.elevationGain = elevationGain
            s.peakLateralG = peakLateralG
            s.gpsAccuracyP50 = gpsAccuracyP50
            s.gpsAccuracyP95 = gpsAccuracyP95
            s.maxLocationGap = maxLocationGap
            s.locationSampleCount = locationSampleCount
            s.motionSampleCount = motionSampleCount
            s.motionDropRate = motionDropRate
            s.batteryUsagePerHour = batteryUsagePerHour
            return s
        }
        set {
            duration = newValue.duration
            distance = newValue.distance
            maxSpeed = newValue.maxSpeed
            avgSpeed = newValue.avgSpeed
            elevationGain = newValue.elevationGain
            peakLateralG = newValue.peakLateralG
            gpsAccuracyP50 = newValue.gpsAccuracyP50
            gpsAccuracyP95 = newValue.gpsAccuracyP95
            maxLocationGap = newValue.maxLocationGap
            locationSampleCount = newValue.locationSampleCount
            motionSampleCount = newValue.motionSampleCount
            motionDropRate = newValue.motionDropRate
            batteryUsagePerHour = newValue.batteryUsagePerHour
        }
    }

    public var sortedMarkers: [Marker] { markers.sorted { $0.elapsed < $1.elapsed } }
}

@Model
public final class Marker {
    public var id: UUID
    public var session: DriveSession?
    public var kind: MarkerKind
    public var elapsed: TimeInterval
    public var date: Date
    public var label: String?

    public init(kind: MarkerKind, elapsed: TimeInterval, date: Date, label: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.elapsed = elapsed
        self.date = date
        self.label = label
    }
}

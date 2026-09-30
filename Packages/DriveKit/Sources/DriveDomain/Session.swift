import Foundation

/// Capture presets (PLAN §2.2.1). Fixed for the lifetime of a session.
public enum CapturePreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case gpsOnly
    case eco
    case vlog
    case logger
    case lab

    public static let `default` = CapturePreset.logger

    public var id: String { rawValue }

    public enum MotionMode: Sendable, Equatable {
        case none
        /// `startAccelerometerUpdates`, gyro off. Stored as `AccelSample`.
        case accelerometer(hz: Double)
        /// `startDeviceMotionUpdates`. Stored as `MotionSample`.
        case deviceMotion(hz: Double)

        public var hz: Double {
            switch self {
            case .none: 0
            case .accelerometer(let hz), .deviceMotion(let hz): hz
            }
        }
    }

    public var motion: MotionMode {
        switch self {
        case .gpsOnly: .none
        case .eco: .accelerometer(hz: 10)
        case .vlog: .deviceMotion(hz: 25)
        case .logger: .deviceMotion(hz: 50)
        case .lab: .deviceMotion(hz: 100)
        }
    }

    /// Live Activity refresh interval, seconds.
    public var liveActivityInterval: TimeInterval {
        switch self {
        case .gpsOnly, .eco: 5
        case .vlog, .logger, .lab: 2
        }
    }

    /// Estimated storage per hour, bytes (PLAN §4.3).
    public var estimatedBytesPerHour: Int {
        let location = LocationSample.recordSize * 3600
        let altitude = AltitudeSample.recordSize * 3600
        let motion: Int = switch motion {
        case .none: 0
        case .accelerometer(let hz): Int(hz) * AccelSample.recordSize * 3600
        case .deviceMotion(let hz): Int(hz) * MotionSample.recordSize * 3600
        }
        return location + altitude + motion
    }
}

/// Persisted lifecycle of a session (SwiftData `DriveSession.state`).
public enum RecordingState: String, Codable, Sendable {
    case recording
    case stopped
    case recovered
    case discarded
}

/// Runtime state of `RecordingController` (PLAN §6).
public enum RecorderPhase: String, Sendable, Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case finalizing
    case stopped
    case interrupted
}

/// Raw values are persisted (SwiftData, JSON `markers[].kind`).
public enum MarkerKind: String, Codable, Sendable {
    /// Video-sync reference point (t = 0 for the VlogTrack).
    case sync
    /// Bookmark: "look at this later".
    case mark
    /// A moment worth cutting to the front camera in the vlog.
    case highlight

    /// `aux` of this marker's `EventKind.marker` record in `events.bin`. Persisted — never renumber.
    public var eventAux: UInt32 {
        switch self {
        case .mark: 0
        case .sync: 1
        case .highlight: 2
        }
    }

    public init?(eventAux: UInt32) {
        switch eventAux {
        case 0: self = .mark
        case 1: self = .sync
        case 2: self = .highlight
        default: return nil
        }
    }
}

public enum EventSource: UInt8, Codable, Sendable {
    case phone = 0
    case liveActivity = 1
    case watch = 2
    case system = 3
}

/// Event kinds stored in `events.bin` (PLAN §9.4). Raw values are persisted — append only.
public enum EventKind: UInt16, Codable, Sendable, CaseIterable {
    case unknown = 0
    case gpsLost = 1
    case gpsResumed = 2
    case motionStalled = 3
    case motionResumed = 4
    case appDidEnterBackground = 5
    case appWillEnterForeground = 6
    case watchdogFired = 7
    case resumedFromNotification = 8
    case calibrationUpdated = 9
    case thermalStateChanged = 10
    case lowPowerModeChanged = 11
    case carPlayConnected = 12
    case carPlayDisconnected = 13
    case screenOn = 14
    case screenOff = 15
    /// value = battery level 0…1 (-1 unknown), aux = UIDevice.BatteryState raw value.
    case batterySnapshot = 16
    case batteryLowSuggested = 17
    /// aux = `MarkerKind.eventAux`; value = the watch's press time (unix s), 0 for the phone and Live Activity.
    case marker = 18
    case sessionResumed = 19
    /// Robust mode continued the session by itself after iOS relaunched the app (value = gap, s).
    case autoResumed = 20
    /// The phone left its mount or moved in it (gravity far from the calibrated up); G is unavailable until the
    /// mount is found again.
    case mountChanged = 21
}

/// Maps each stream's native clock to session elapsed time (PLAN §3).
public struct SessionClock: Sendable, Equatable, Codable {
    /// Absolute start, UTC.
    public var startedAt: Date
    /// `ProcessInfo.systemUptime` at start (Core Motion clock).
    public var startUptime: TimeInterval

    public init(startedAt: Date, startUptime: TimeInterval) {
        self.startedAt = startedAt
        self.startUptime = startUptime
    }

    /// For Location samples (absolute timestamps, seconds since 1970).
    public func elapsed(unixTime: Double) -> TimeInterval { unixTime - startedAt.timeIntervalSince1970 }
    /// For Motion / Altitude samples (systemUptime timestamps).
    public func elapsed(uptime: Double) -> TimeInterval { uptime - startUptime }
    public func date(elapsed: TimeInterval) -> Date { startedAt.addingTimeInterval(elapsed) }
}

public enum PlaceRole: String, Codable, Sendable {
    case start
    case end
    case maxAltitude
    case peakG
    case via
}

/// Reverse-geocoded place (PLAN §4.2 / §8).
public struct PlaceMeta: Codable, Sendable, Equatable {
    public var name: String?
    public var locality: String?
    public var subLocality: String?
    public var administrativeArea: String?
    public var fullAddress: String?
    public var mapItemIdentifier: String?
    public var latitude: Double
    public var longitude: Double
    public var role: PlaceRole

    public init(
        name: String? = nil, locality: String? = nil, subLocality: String? = nil,
        administrativeArea: String? = nil, fullAddress: String? = nil, mapItemIdentifier: String? = nil,
        latitude: Double, longitude: Double, role: PlaceRole
    ) {
        self.name = name
        self.locality = locality
        self.subLocality = subLocality
        self.administrativeArea = administrativeArea
        self.fullAddress = fullAddress
        self.mapItemIdentifier = mapItemIdentifier
        self.latitude = latitude
        self.longitude = longitude
        self.role = role
    }

    /// Short label for titles: locality, falling back to sub-locality / area / name.
    public var shortName: String? { locality ?? subLocality ?? administrativeArea ?? name }
}

/// Device → vehicle rotation (PLAN §7). Vehicle axes: x = forward, y = left, z = up.
public struct MountCalibration: Codable, Sendable, Equatable {
    public enum Method: String, Codable, Sendable {
        case auto
        case manual
    }

    /// Row-major 3x3 rotation matrix, device frame → vehicle frame.
    public var rotation: [Double]
    public var method: Method
    /// 0…1.
    public var confidence: Double
    public var calibratedAtElapsed: TimeInterval

    public init(rotation: [Double], method: Method, confidence: Double, calibratedAtElapsed: TimeInterval) {
        precondition(rotation.count == 9, "rotation must be 3x3")
        self.rotation = rotation
        self.method = method
        self.confidence = confidence
        self.calibratedAtElapsed = calibratedAtElapsed
    }

    public static let identity = MountCalibration(
        rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1], method: .manual, confidence: 0, calibratedAtElapsed: 0
    )

    /// Applies the rotation to a device-frame vector.
    public func apply(_ v: Vector3) -> Vector3 {
        let r = rotation.map(Float.init)
        return Vector3(
            x: r[0] * v.x + r[1] * v.y + r[2] * v.z,
            y: r[3] * v.x + r[4] * v.y + r[5] * v.z,
            z: r[6] * v.x + r[7] * v.y + r[8] * v.z
        )
    }
}

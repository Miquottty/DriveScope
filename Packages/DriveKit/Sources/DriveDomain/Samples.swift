/// Raw samples as captured, in device coordinates and unsmoothed (PLAN §18 rule 1).
/// Timestamps keep each source's native clock; normalize with `SessionClock`.

/// One Core Location fix. 72 bytes.
public struct LocationSample: BinaryRecord, Equatable {
    /// Absolute time of the fix (`CLLocation.timestamp`), seconds since 1970.
    public var timestamp: Double
    public var latitude: Double
    public var longitude: Double
    /// Altitude above mean sea level, meters.
    public var altitude: Double
    /// `ProcessInfo.systemUptime` when the fix was delivered. Lets GPS be aligned to the motion clock.
    public var receivedUptime: Double
    /// m/s, negative when invalid.
    public var speed: Float
    /// Degrees from true north, negative when invalid.
    public var course: Float
    public var horizontalAccuracy: Float
    public var verticalAccuracy: Float
    public var speedAccuracy: Float
    public var courseAccuracy: Float
    public var flags: Flags

    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let simulatedBySoftware = Flags(rawValue: 1 << 0)
        public static let producedByAccessory = Flags(rawValue: 1 << 1)
        /// Synthesized by the app's own simulator sources (DriveScript), never set on device.
        public static let synthetic = Flags(rawValue: 1 << 2)
    }

    public static let recordSize = 72

    public init(
        timestamp: Double, latitude: Double, longitude: Double, altitude: Double, receivedUptime: Double,
        speed: Float, course: Float, horizontalAccuracy: Float, verticalAccuracy: Float,
        speedAccuracy: Float, courseAccuracy: Float, flags: Flags = []
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.receivedUptime = receivedUptime
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speedAccuracy = speedAccuracy
        self.courseAccuracy = courseAccuracy
        self.flags = flags
    }

    public var hasValidSpeed: Bool { speed >= 0 }
    public var hasValidCourse: Bool { course >= 0 }
    /// From the satellites, not Wi‑Fi / cell positioning: Core Location's speed is Doppler-derived, so only a
    /// satellite fix carries one (on device the Wi‑Fi fixes before the first lock have speed and its accuracy -1).
    public var isSatelliteFix: Bool { hasValidSpeed }

    public func encode(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) {
        var w = RecordWriter(buffer, at: offset)
        w.put(timestamp); w.put(latitude); w.put(longitude); w.put(altitude); w.put(receivedUptime)
        w.put(speed); w.put(course)
        w.put(horizontalAccuracy); w.put(verticalAccuracy); w.put(speedAccuracy); w.put(courseAccuracy)
        w.put(flags.rawValue); w.put(UInt32(0))
    }

    public init(decoding buffer: UnsafeRawBufferPointer, at offset: Int) {
        var r = RecordReader(buffer, at: offset)
        timestamp = r.double(); latitude = r.double(); longitude = r.double(); altitude = r.double()
        receivedUptime = r.double()
        speed = r.float(); course = r.float()
        horizontalAccuracy = r.float(); verticalAccuracy = r.float(); speedAccuracy = r.float(); courseAccuracy = r.float()
        flags = Flags(rawValue: r.get())
        _ = r.get(UInt32.self)
    }
}

/// One `CMDeviceMotion` update. 76 bytes (PLAN listed 72 B; +4 B keeps the magnetic-field accuracy).
public struct MotionSample: BinaryRecord, Equatable {
    /// `CMLogItem.timestamp` — seconds since boot (systemUptime clock).
    public var timestamp: Double
    /// In g, gravity removed.
    public var userAcceleration: Vector3
    /// In g.
    public var gravity: Vector3
    /// rad/s.
    public var rotationRate: Vector3
    public var attitude: Quaternion
    /// Calibrated magnetic field, microtesla.
    public var magneticField: Vector3
    /// `CMMagneticFieldCalibrationAccuracy` raw value (-1 uncalibrated … 2 high).
    public var magneticAccuracy: Int32

    public static let recordSize = 76

    public init(
        timestamp: Double, userAcceleration: Vector3, gravity: Vector3, rotationRate: Vector3,
        attitude: Quaternion, magneticField: Vector3 = .zero, magneticAccuracy: Int32 = -1
    ) {
        self.timestamp = timestamp
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.rotationRate = rotationRate
        self.attitude = attitude
        self.magneticField = magneticField
        self.magneticAccuracy = magneticAccuracy
    }

    public func encode(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) {
        var w = RecordWriter(buffer, at: offset)
        w.put(timestamp)
        userAcceleration.write(to: &w); gravity.write(to: &w); rotationRate.write(to: &w)
        w.put(attitude.w); w.put(attitude.x); w.put(attitude.y); w.put(attitude.z)
        magneticField.write(to: &w)
        w.put(magneticAccuracy)
    }

    public init(decoding buffer: UnsafeRawBufferPointer, at offset: Int) {
        var r = RecordReader(buffer, at: offset)
        timestamp = r.double()
        userAcceleration = Vector3(reading: &r); gravity = Vector3(reading: &r); rotationRate = Vector3(reading: &r)
        attitude = Quaternion(w: r.float(), x: r.float(), y: r.float(), z: r.float())
        magneticField = Vector3(reading: &r)
        magneticAccuracy = r.get()
    }
}

/// Accelerometer-only update (Eco preset). Raw acceleration including gravity, in g. 20 bytes.
public struct AccelSample: BinaryRecord, Equatable {
    public var timestamp: Double
    public var acceleration: Vector3

    public static let recordSize = 20

    public init(timestamp: Double, acceleration: Vector3) {
        self.timestamp = timestamp
        self.acceleration = acceleration
    }

    public func encode(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) {
        var w = RecordWriter(buffer, at: offset)
        w.put(timestamp)
        acceleration.write(to: &w)
    }

    public init(decoding buffer: UnsafeRawBufferPointer, at offset: Int) {
        var r = RecordReader(buffer, at: offset)
        timestamp = r.double()
        acceleration = Vector3(reading: &r)
    }
}

/// One `CMAltitudeData` update. 16 bytes.
public struct AltitudeSample: BinaryRecord, Equatable {
    /// systemUptime clock.
    public var timestamp: Double
    /// Meters relative to the first reading of the session.
    public var relativeAltitude: Float
    /// kPa.
    public var pressure: Float

    public static let recordSize = 16

    public init(timestamp: Double, relativeAltitude: Float, pressure: Float) {
        self.timestamp = timestamp
        self.relativeAltitude = relativeAltitude
        self.pressure = pressure
    }

    public func encode(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) {
        var w = RecordWriter(buffer, at: offset)
        w.put(timestamp); w.put(relativeAltitude); w.put(pressure)
    }

    public init(decoding buffer: UnsafeRawBufferPointer, at offset: Int) {
        var r = RecordReader(buffer, at: offset)
        timestamp = r.double(); relativeAltitude = r.float(); pressure = r.float()
    }
}

/// A session event (PLAN §9.4). 24 bytes.
public struct EventRecord: BinaryRecord, Equatable {
    public var kind: EventKind
    public var source: EventSource
    /// Kind-specific small integer payload (e.g. charging state, thermal state raw value).
    public var aux: UInt32
    /// Seconds since session start.
    public var elapsed: Double
    /// Kind-specific numeric payload (e.g. battery level 0…1, gap seconds).
    public var value: Double

    public static let recordSize = 24

    public init(kind: EventKind, source: EventSource = .phone, aux: UInt32 = 0, elapsed: Double, value: Double = 0) {
        self.kind = kind
        self.source = source
        self.aux = aux
        self.elapsed = elapsed
        self.value = value
    }

    public func encode(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) {
        var w = RecordWriter(buffer, at: offset)
        w.put(kind.rawValue); w.put(source.rawValue); w.put(UInt8(0)); w.put(aux)
        w.put(elapsed); w.put(value)
    }

    public init(decoding buffer: UnsafeRawBufferPointer, at offset: Int) {
        var r = RecordReader(buffer, at: offset)
        kind = EventKind(rawValue: r.get()) ?? .unknown
        source = EventSource(rawValue: r.get()) ?? .phone
        _ = r.get(UInt8.self)
        aux = r.get()
        elapsed = r.double()
        value = r.double()
    }
}

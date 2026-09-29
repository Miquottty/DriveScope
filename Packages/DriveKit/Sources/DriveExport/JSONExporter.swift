import DriveDomain
import DriveReplay
import DriveStorage
import Foundation

/// The lossless master export (PLAN §12, §18 rule 8). Streams straight to disk, one row per line.
///
/// Timestamps are kept exactly as recorded, each in its stream's native clock (PLAN §3):
/// - `location.timestamp` — Unix seconds; elapsed = timestamp − `session.startedAtUnix`
/// - `motion.timestamp`, `altitude.timestamp`, `location.receivedUptime` — system uptime seconds;
///   elapsed = timestamp − `session.startUptime`
/// - `events.elapsed`, `markers.elapsed` — already seconds since session start
///
/// Numbers use the shortest round-trip decimal form (Float fields are printed as Float, so they parse back
/// to the identical bit pattern). Non-finite values are `null`. `startedAt` / `endedAt` / marker dates are
/// ISO 8601 UTC with milliseconds; `startedAtUnix` carries the exact start as a raw Double.
///
/// Row layouts are given by each block's `fields` array. `location.flags` is `LocationSample.Flags.rawValue`.
/// `session.summary` uses SI units (m, m/s, s, g).
public enum JSONExporter {
    public static let format = "drivescope.session"
    public static let version = 1

    public static let locationFields = [
        "timestamp", "latitude", "longitude", "altitude", "receivedUptime", "speed", "course",
        "horizontalAccuracy", "verticalAccuracy", "speedAccuracy", "courseAccuracy", "flags",
    ]
    public static let deviceMotionFields = [
        "timestamp", "userAccelerationX", "userAccelerationY", "userAccelerationZ",
        "gravityX", "gravityY", "gravityZ", "rotationRateX", "rotationRateY", "rotationRateZ",
        "attitudeW", "attitudeX", "attitudeY", "attitudeZ",
        "magneticFieldX", "magneticFieldY", "magneticFieldZ", "magneticAccuracy",
    ]
    public static let accelerometerFields = ["timestamp", "accelerationX", "accelerationY", "accelerationZ"]
    public static let altitudeFields = ["timestamp", "relativeAltitude", "pressure"]

    public static func export(reader: TelemetryReader, metadata: ExportMetadata, to url: URL) throws {
        let out = try BufferedFileWriter(url: url)
        try write(reader: reader, metadata: metadata, to: out)
        try out.close()
    }

    private static func write(reader: TelemetryReader, metadata: ExportMetadata, to out: BufferedFileWriter) throws {
        let manifest = reader.manifest
        var head = "{\"format\":"
        head.appendJSON(format)
        head += ",\"version\":\(version),\n\"session\":"
        head += sessionObject(manifest: manifest, metadata: metadata)
        head += ",\n\"places\":["
        for (i, place) in metadata.places.enumerated() {
            head += i == 0 ? "\n" : ",\n"
            head += placeObject(place)
        }
        head += "],\n\"markers\":["
        for (i, marker) in metadata.markers.enumerated() {
            head += i == 0 ? "\n" : ",\n"
            head += "{\"kind\":"
            head.appendJSON(marker.kind.rawValue)
            head += ",\"elapsed\":"
            head.appendJSON(marker.elapsed)
            head += ",\"date\":"
            head.appendJSONDate(marker.date.timeIntervalSince1970)
            head += ",\"label\":"
            head.appendJSON(marker.label)
            head += "}"
        }
        head += "],\n\"events\":["
        try out.write(head)

        var line = ""
        for (i, event) in reader.events.enumerated() {
            line = i == 0 ? "\n" : ",\n"
            line += "{\"kind\":"
            line.appendJSON("\(event.kind)")
            line += ",\"source\":"
            line.appendJSON("\(event.source)")
            line += ",\"aux\":\(event.aux),\"elapsed\":"
            line.appendJSON(event.elapsed)
            line += ",\"value\":"
            line.appendJSON(event.value)
            line += "}"
            try out.write(line)
        }
        try out.write("],\n\"location\":")
        try writeBlock(fields: locationFields, rows: reader.locations, to: out) { s, row in
            row.add(s.timestamp); row.add(s.latitude); row.add(s.longitude); row.add(s.altitude)
            row.add(s.receivedUptime)
            row.add(s.speed); row.add(s.course)
            row.add(s.horizontalAccuracy); row.add(s.verticalAccuracy); row.add(s.speedAccuracy); row.add(s.courseAccuracy)
            row.add(s.flags.rawValue)
        }

        try out.write(",\n\"motion\":")
        switch manifest.motionStream {
        case .motion:
            try writeBlock(typeJSON: "\"deviceMotion\"", fields: deviceMotionFields, rows: reader.motion, to: out) { s, row in
                row.add(s.timestamp)
                row.add(s.userAcceleration.x); row.add(s.userAcceleration.y); row.add(s.userAcceleration.z)
                row.add(s.gravity.x); row.add(s.gravity.y); row.add(s.gravity.z)
                row.add(s.rotationRate.x); row.add(s.rotationRate.y); row.add(s.rotationRate.z)
                row.add(s.attitude.w); row.add(s.attitude.x); row.add(s.attitude.y); row.add(s.attitude.z)
                row.add(s.magneticField.x); row.add(s.magneticField.y); row.add(s.magneticField.z)
                row.add(s.magneticAccuracy)
            }
        case .accel:
            try writeBlock(typeJSON: "\"accelerometer\"", fields: accelerometerFields, rows: reader.accelerations, to: out) { s, row in
                row.add(s.timestamp)
                row.add(s.acceleration.x); row.add(s.acceleration.y); row.add(s.acceleration.z)
            }
        default:
            try writeBlock(typeJSON: "null", fields: [], rows: [LocationSample](), to: out) { _, _ in }
        }

        try out.write(",\n\"altitude\":")
        try writeBlock(fields: altitudeFields, rows: reader.altitudes, to: out) { s, row in
            row.add(s.timestamp); row.add(s.relativeAltitude); row.add(s.pressure)
        }
        try out.write("}\n")
    }

    /// `{"fields":[...],"rows":[\n[..],\n[..]]}` (with an optional leading `"type"`).
    private static func writeBlock<S: Sequence>(
        typeJSON: String? = nil, fields: [String], rows: S, to out: BufferedFileWriter,
        _ encode: (S.Element, inout JSONRow) -> Void
    ) throws {
        var head = "{"
        if let typeJSON { head += "\"type\":" + typeJSON + "," }
        head += "\"fields\":["
        for (i, field) in fields.enumerated() {
            if i > 0 { head += "," }
            head.appendJSON(field)
        }
        head += "],\"rows\":["
        try out.write(head)
        var row = JSONRow()
        var first = true
        for element in rows {
            row.reset()
            encode(element, &row)
            try out.write((first ? "\n[" : ",\n[") + row.text + "]")
            first = false
        }
        try out.write("]}")
    }

    private static func sessionObject(manifest: SessionManifest, metadata: ExportMetadata) -> String {
        let clock = manifest.clock
        var s = "{\"id\":"
        s.appendJSON(manifest.sessionID.uuidString)
        s += ",\"title\":"
        s.appendJSON(metadata.title)
        s += ",\"notes\":"
        s.appendJSON(metadata.notes)
        s += ",\"startedAt\":"
        s.appendJSONDate(clock.startedAt.timeIntervalSince1970)
        s += ",\"startedAtUnix\":"
        s.appendJSON(clock.startedAt.timeIntervalSince1970)
        s += ",\"endedAt\":"
        if let ended = manifest.endedAt { s.appendJSONDate(ended.timeIntervalSince1970) } else { s += "null" }
        s += ",\"timeZone\":"
        s.appendJSON(manifest.timeZoneID)
        s += ",\"preset\":"
        s.appendJSON(manifest.preset.rawValue)
        s += ",\"appVersion\":"
        s.appendJSON(manifest.appVersion)
        s += ",\"deviceModel\":"
        s.appendJSON(manifest.deviceModel)
        s += ",\"osVersion\":"
        s.appendJSON(manifest.osVersion)
        s += ",\"startUptime\":"
        s.appendJSON(clock.startUptime)
        s += ",\"altitudeBaseline\":"
        if let baseline = manifest.altitudeBaseline { s.appendJSON(baseline) } else { s += "null" }
        s += ",\"calibration\":"
        if let c = manifest.calibration {
            var row = JSONRow()
            c.rotation.forEach { row.add($0) }
            s += "{\"rotation\":[\(row.text)],\"method\":"
            s.appendJSON(c.method.rawValue)
            s += ",\"confidence\":"
            s.appendJSON(c.confidence)
            s += ",\"calibratedAtElapsed\":"
            s.appendJSON(c.calibratedAtElapsed)
            s += "}"
        } else {
            s += "null"
        }
        s += ",\"summary\":" + summaryObject(metadata.summary) + "}"
        return s
    }

    private static func summaryObject(_ m: SessionSummary) -> String {
        var s = "{"
        func number(_ key: String, _ value: Double, last: Bool = false) {
            s += "\"\(key)\":"
            s.appendJSON(value)
            if !last { s += "," }
        }
        number("duration", m.duration)
        number("distance", m.distance)
        number("maxSpeed", m.maxSpeed)
        number("avgSpeed", m.avgSpeed)
        number("elevationGain", m.elevationGain)
        number("peakLateralG", m.peakLateralG)
        number("gpsAccuracyP50", m.gpsAccuracyP50)
        number("gpsAccuracyP95", m.gpsAccuracyP95)
        number("maxLocationGap", m.maxLocationGap)
        s += "\"locationSampleCount\":\(m.locationSampleCount),\"motionSampleCount\":\(m.motionSampleCount),"
        number("motionDropRate", m.motionDropRate)
        s += "\"batteryUsagePerHour\":"
        if let battery = m.batteryUsagePerHour { s.appendJSON(battery) } else { s += "null" }
        return s + "}"
    }

    private static func placeObject(_ p: PlaceMeta) -> String {
        var s = "{"
        func text(_ key: String, _ value: String?) {
            s += "\"\(key)\":"
            s.appendJSON(value)
            s += ","
        }
        text("name", p.name)
        text("locality", p.locality)
        text("subLocality", p.subLocality)
        text("administrativeArea", p.administrativeArea)
        text("fullAddress", p.fullAddress)
        text("mapItemIdentifier", p.mapItemIdentifier)
        s += "\"latitude\":"
        s.appendJSON(p.latitude)
        s += ",\"longitude\":"
        s.appendJSON(p.longitude)
        s += ",\"role\":"
        s.appendJSON(p.role.rawValue)
        return s + "}"
    }
}

import DriveDomain
import DriveReplay
import Foundation

/// GPX 1.1 for other tools (PLAN §12). Compatibility format only — JSON is the master (PLAN §18 rule 8).
///
/// One `<trk>` whose `<trkseg>`s are split wherever consecutive fixes are more than 30 s apart. Fixes with
/// `horizontalAccuracy <= 0` (invalid) are skipped.
///
/// Per `<trkpt>`, inside `<extensions>`: GPS speed (m/s), course and accuracies, one-second G summaries and the
/// barometric altitude under the `ds:` namespace, plus speed / course again as Garmin TrackPointExtension v2 for
/// tools that only know that. Only 1-second summaries go here; 50 Hz data belongs to the JSON master.
///
/// G values keep the engine's ISO 8855 signs in every file (lateral + = left, longitudinal + = accelerating,
/// vertical + = up; 1 g = 9.80665 m/s²), declared once in `<metadata><extensions>`. The on-screen G meter plots
/// the felt force instead, but that is display-only.
///
/// Markers and detected sections become `<wpt>`s in time order, each with a `<type>`.
public enum GPXExporter {
    public static let segmentGap: TimeInterval = 30
    public static let namespace = "urn:drivescope:gpx:1"
    public static let garminNamespace = "http://www.garmin.com/xmlschemas/TrackPointExtension/v2"

    /// Longest altitude-sample interval still treated as continuous; a barometer dropout leaves `ds:baroAlt` out.
    private static let baroMaxGap: TimeInterval = 5
    /// How far outside the altitude stream a fix may sit and still take the nearest reading.
    private static let baroEdgeTolerance: TimeInterval = 2

    public static func export(reader: TelemetryReader, metadata: ExportMetadata, to url: URL) throws {
        let clock = reader.clock
        let out = try BufferedFileWriter(url: url)
        // First, because `<metadata>` declares where the G values come from.
        let gTrack = GSummaryTrack(reader: reader)

        var head = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="DriveScope" xmlns="http://www.topografix.com/GPX/1/1" xmlns:ds="\(namespace)" xmlns:gpxtpx="\(garminNamespace)">
        <metadata>

        """
        if !metadata.title.isEmpty { head += "<name>\(metadata.title.xmlEscaped)</name>\n" }
        if !metadata.notes.isEmpty { head += "<desc>\(metadata.notes.xmlEscaped)</desc>\n" }
        head += "<time>"
        head.appendISO8601(unixTime: clock.startedAt.timeIntervalSince1970)
        head += "</time>\n"
        // `<extensions>` is the last child of `<metadata>` in GPX 1.1.
        head += """
        <extensions>
        <ds:axes lateral="+left" longitudinal="+accelerating" vertical="+up"/>
        <ds:gUnit>\(Units.g)</ds:gUnit>
        <ds:gSource>\(gTrack.source.rawValue)</ds:gSource>
        <ds:gWindow>\(GSummaryTrack.window)</ds:gWindow>
        </extensions>
        </metadata>

        """
        try out.write(head)

        // A waypoint's position needs fixes to interpolate between; without any, it would be a lie at 0,0.
        if !reader.locations.isEmpty {
            for waypoint in waypoints(reader: reader, metadata: metadata, gTrack: gTrack) {
                try out.write(waypoint)
            }
        }

        try out.write("<trk>\n")
        if !metadata.title.isEmpty { try out.write("<name>\(metadata.title.xmlEscaped)</name>\n") }
        var lastTimestamp: Double?
        var inSegment = false
        var point = ""
        for fix in reader.locations where fix.horizontalAccuracy > 0 {
            if inSegment, let last = lastTimestamp, fix.timestamp - last > segmentGap {
                try out.write("</trkseg>\n")
                inSegment = false
            }
            if !inSegment {
                try out.write("<trkseg>\n")
                inSegment = true
            }
            lastTimestamp = fix.timestamp

            point.removeAll(keepingCapacity: true)
            point += "<trkpt lat=\""
            point.appendFixed(fix.latitude, decimals: 7)
            point += "\" lon=\""
            point.appendFixed(fix.longitude, decimals: 7)
            point += "\">"
            // Negative vertical accuracy means Core Location has no valid altitude for this fix.
            if fix.verticalAccuracy >= 0 {
                point += "<ele>"
                point.appendFixed(fix.altitude, decimals: 2)
                point += "</ele>"
            }
            point += "<time>"
            point.appendISO8601(unixTime: fix.timestamp)
            point += "</time><extensions>"
            if fix.hasValidSpeed {
                point += "<ds:speed>"
                point.appendFixed(Double(fix.speed), decimals: 2)
                point += "</ds:speed>"
            }
            if fix.hasValidCourse {
                point += "<ds:course>"
                point.appendFixed(Double(fix.course), decimals: 1)
                point += "</ds:course>"
            }
            point += "<ds:hAcc>"
            point.appendFixed(Double(fix.horizontalAccuracy), decimals: 1)
            point += "</ds:hAcc>"
            if fix.verticalAccuracy >= 0 {
                point += "<ds:vAcc>"
                point.appendFixed(Double(fix.verticalAccuracy), decimals: 1)
                point += "</ds:vAcc>"
            }
            let elapsed = clock.elapsed(unixTime: fix.timestamp)
            if let g = gTrack.summary(around: elapsed) {
                point += "<ds:latG>"
                point.appendFixed(g.lateral, decimals: 3)
                point += "</ds:latG>"
                if let longitudinal = g.longitudinal {
                    point += "<ds:longG>"
                    point.appendFixed(longitudinal, decimals: 3)
                    point += "</ds:longG>"
                }
                point += "<ds:peakLatG>"
                point.appendFixed(g.peakLateral, decimals: 3)
                point += "</ds:peakLatG>"
            }
            // Its own element, not `<ele>`: other tools read `<ele>` as GPS altitude.
            if let baro = baroAltitude(reader.altitudes, atUptime: clock.startUptime + elapsed) {
                point += "<ds:baroAlt>"
                point.appendFixed(baro, decimals: 2)
                point += "</ds:baroAlt>"
            }
            if fix.hasValidSpeed || fix.hasValidCourse {
                point += "<gpxtpx:TrackPointExtension>"
                if fix.hasValidSpeed {
                    point += "<gpxtpx:speed>"
                    point.appendFixed(Double(fix.speed), decimals: 2)
                    point += "</gpxtpx:speed>"
                }
                if fix.hasValidCourse {
                    point += "<gpxtpx:course>"
                    point.appendFixed(Double(fix.course), decimals: 1)
                    point += "</gpxtpx:course>"
                }
                point += "</gpxtpx:TrackPointExtension>"
            }
            point += "</extensions></trkpt>\n"
            try out.write(point)
        }
        if inSegment { try out.write("</trkseg>\n") }
        try out.write("</trk>\n</gpx>\n")
        try out.close()
    }

    // MARK: - Waypoints

    /// Markers and sections as `<wpt>` lines, ordered by time.
    private static func waypoints(reader: TelemetryReader, metadata: ExportMetadata, gTrack: GSummaryTrack) -> [String] {
        struct Waypoint {
            var elapsed: TimeInterval
            var date: Date
            var name: String
            var type: String
            var frame: ReplayTelemetryFrame
        }
        let interpolator = TelemetryInterpolator(reader: reader)
        var waypoints: [Waypoint] = []

        // SYNCs are numbered in time order ("SYNC 1", "SYNC 2", …) so a video editor can tell which clip each
        // one starts when the camera was restarted during the drive.
        var syncCount = 0
        for marker in metadata.markers.sorted(by: { $0.elapsed < $1.elapsed }) {
            var name: String
            // No `default`: a new MarkerKind must get its waypoint name here, not silently become "MARK".
            switch marker.kind {
            case .sync:
                syncCount += 1
                name = "SYNC \(syncCount)"
            case .mark:
                name = "MARK"
            case .highlight:
                name = "HIGHLIGHT"
            }
            if let label = marker.label, !label.isEmpty { name += ": " + label }
            waypoints.append(Waypoint(
                elapsed: marker.elapsed, date: marker.date, name: name, type: marker.kind.rawValue,
                frame: interpolator.frame(at: marker.elapsed)
            ))
        }

        // "Corner 3" is the third corner of the drive, "Stop 2" the second stop.
        var counts: [DriveSection.Kind: Int] = [:]
        for section in metadata.sections.sorted(by: { $0.start < $1.start }) {
            counts[section.kind, default: 0] += 1
            var name = "\(label(of: section.kind)) \(counts[section.kind] ?? 0)"
            // A corner sits at its peak-G point; a stop where the car stopped; a climb / descent where it starts.
            var at = section.start
            switch section.kind {
            case .corner:
                if let g = section.peakLateralG {
                    name += " · "
                    name.appendFixed(g, decimals: 2)
                    name += " G"
                }
                at = gTrack.peakTime(from: section.start, to: section.end) ?? (section.start + section.end) / 2
            case .stop:
                name += " · \(Int(section.duration.rounded())) s"
            case .climb, .descent:
                if let change = section.altitudeChange {
                    name += " · " + (change >= 0 ? "+" : "")
                    name.appendFixed(change, decimals: 0)
                    name += " m"
                }
            }
            waypoints.append(Waypoint(
                elapsed: at, date: reader.clock.date(elapsed: at), name: name, type: section.kind.rawValue,
                frame: interpolator.frame(at: at)
            ))
        }

        // Stable for equal times (a marker before the section it was dropped in).
        let ordered = waypoints.enumerated().sorted {
            $0.element.elapsed != $1.element.elapsed ? $0.element.elapsed < $1.element.elapsed : $0.offset < $1.offset
        }
        return ordered.map { _, waypoint in
            var wpt = "<wpt lat=\""
            wpt.appendFixed(waypoint.frame.latitude, decimals: 7)
            wpt += "\" lon=\""
            wpt.appendFixed(waypoint.frame.longitude, decimals: 7)
            wpt += "\"><ele>"
            wpt.appendFixed(waypoint.frame.altitude, decimals: 2)
            wpt += "</ele><time>"
            wpt.appendISO8601(unixTime: waypoint.date.timeIntervalSince1970)
            wpt += "</time><name>\(waypoint.name.xmlEscaped)</name><type>\(waypoint.type)</type></wpt>\n"
            return wpt
        }
    }

    private static func label(of kind: DriveSection.Kind) -> String {
        switch kind {
        case .corner: "Corner"
        case .climb: "Climb"
        case .descent: "Descent"
        case .stop: "Stop"
        }
    }

    // MARK: - Barometer

    /// Altitude relative to the first reading (CMAltimeter's own zero), linearly interpolated to `uptime`.
    /// nil when the stream is empty, the fix lies outside it, or the barometer dropped out around it.
    private static func baroAltitude(_ samples: MappedStream<AltitudeSample>, atUptime uptime: Double) -> Double? {
        guard let first = samples.first, let last = samples.last,
              uptime >= first.timestamp - baroEdgeTolerance, uptime <= last.timestamp + baroEdgeTolerance else { return nil }
        let i = samples.partitionIndex(where: { $0.timestamp }, isAtLeast: uptime)
        let a = samples[max(i - 1, 0)], b = samples[min(i, samples.count - 1)]
        let span = b.timestamp - a.timestamp
        guard span <= baroMaxGap else { return nil }
        let f = span > 0 ? min(max((uptime - a.timestamp) / span, 0), 1) : 0
        return Double(a.relativeAltitude) + Double(b.relativeAltitude - a.relativeAltitude) * f
    }
}

/// The G values of a drive at 10 Hz in the vehicle frame (engine signs), so each `<trkpt>` can summarize the
/// second around its fix without walking the 50 Hz motion stream fix by fix (PLAN §12).
private struct GSummaryTrack {
    /// Where the numbers come from; declared once in `<metadata>`.
    enum Source: String {
        /// Calibrated device motion while the phone sits in its mount: lateral, longitudinal and peak.
        case motion
        /// No usable motion G anywhere in the drive: lateral only, estimated from GPS speed × course rate.
        case gpsEstimate = "gps-estimate"
        case none
    }

    private struct Sample {
        var lateral: Double
        var longitudinal: Double
        var hasMotion: Bool
        var hasFix: Bool
    }

    static let rate = 10.0
    /// Seconds, centred on the fix.
    static let window = 1.0

    let source: Source
    private let samples: [Sample]

    init(reader: TelemetryReader) {
        guard !reader.locations.isEmpty, reader.duration > 0 else {
            source = .none
            samples = []
            return
        }
        // One sample averages exactly one grid step, so the 10 frames of a window cover the second without gaps or
        // overlap; speed fusion only matters for speed, which this pass doesn't read.
        let interpolator = TelemetryInterpolator(
            reader: reader, options: .init(speedWindow: 1, gWindow: 1 / Self.rate, speedFusion: false)
        )
        samples = (0...Int(reader.duration * Self.rate)).map { i in
            let frame = interpolator.frame(at: Double(i) / Self.rate)
            return Sample(
                lateral: frame.lateralG, longitudinal: frame.longitudinalG, hasMotion: frame.hasMotionG, hasFix: frame.hasFix
            )
        }
        // As SectionDetector.peakLateral: the GPS estimate only stands in for a drive with no motion G at all, so a
        // file never mixes the two within one declared source.
        if samples.contains(where: \.hasMotion) {
            source = .motion
        } else if samples.contains(where: \.hasFix) {
            source = .gpsEstimate
        } else {
            source = .none
        }
    }

    private func isValid(_ sample: Sample) -> Bool {
        switch source {
        case .motion: sample.hasMotion
        case .gpsEstimate: sample.hasFix
        case .none: false
        }
    }

    /// Indices of the grid points in [t - window / 2, t + window / 2), clamped to the track.
    private func indices(from t0: TimeInterval, to t1: TimeInterval) -> Range<Int> {
        let lower = max(0, Int((t0 * Self.rate).rounded(.up)))
        let upper = min(samples.count, Int((t1 * Self.rate).rounded(.up)))
        return lower < upper ? lower..<upper : 0..<0
    }

    /// Mean lateral / longitudinal g and the lateral value of largest magnitude (signed) over the window around
    /// `t`; nil when no sample in it has G (phone out of the mount, GPS gap, no motion).
    func summary(around t: TimeInterval) -> (lateral: Double, longitudinal: Double?, peakLateral: Double)? {
        var lateral = 0.0, longitudinal = 0.0, peak = 0.0, n = 0.0
        for i in indices(from: t - Self.window / 2, to: t + Self.window / 2) where isValid(samples[i]) {
            let s = samples[i]
            lateral += s.lateral
            longitudinal += s.longitudinal
            if abs(s.lateral) > abs(peak) { peak = s.lateral }
            n += 1
        }
        guard n > 0 else { return nil }
        // The GPS estimate has no longitudinal part (the frame's 0 would pass for a measurement).
        return (lateral / n, source == .motion ? longitudinal / n : nil, peak)
    }

    /// When |lateral g| peaks inside [start, end]; nil when no sample there has G.
    func peakTime(from start: TimeInterval, to end: TimeInterval) -> TimeInterval? {
        var best: Int?
        var bestG = -1.0
        for i in indices(from: start, to: end + 1 / Self.rate) where isValid(samples[i]) && abs(samples[i].lateral) > bestG {
            best = i
            bestG = abs(samples[i].lateral)
        }
        return best.map { Double($0) / Self.rate }
    }
}

import DriveDomain
import DriveReplay
import Foundation

/// GPX 1.1 for other tools (PLAN §12). Compatibility format only — JSON is the master (PLAN §18 rule 8).
///
/// One `<trk>` whose `<trkseg>`s are split wherever consecutive fixes are more than 30 s apart. Fixes with
/// `horizontalAccuracy <= 0` (invalid) are skipped. Speed (m/s), course and horizontal accuracy go into
/// `<extensions>` under the `ds:` namespace; markers become `<wpt>` at their interpolated position.
public enum GPXExporter {
    public static let segmentGap: TimeInterval = 30
    public static let namespace = "urn:drivescope:gpx:1"

    public static func export(reader: TelemetryReader, metadata: ExportMetadata, to url: URL) throws {
        let clock = reader.clock
        let out = try BufferedFileWriter(url: url)

        var head = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="DriveScope" xmlns="http://www.topografix.com/GPX/1/1" xmlns:ds="\(namespace)">
        <metadata>

        """
        if !metadata.title.isEmpty { head += "<name>\(metadata.title.xmlEscaped)</name>\n" }
        if !metadata.notes.isEmpty { head += "<desc>\(metadata.notes.xmlEscaped)</desc>\n" }
        head += "<time>"
        head.appendISO8601(unixTime: clock.startedAt.timeIntervalSince1970)
        head += "</time>\n</metadata>\n"
        try out.write(head)

        // A marker's position needs fixes to interpolate between; without any, a waypoint would be a lie at 0,0.
        if !reader.locations.isEmpty {
            let interpolator = TelemetryInterpolator(reader: reader)
            // SYNCs are numbered in time order ("SYNC 1", "SYNC 2", …) so a video editor can tell which clip each
            // one starts when the camera was restarted during the drive.
            var syncCount = 0
            for marker in metadata.markers.sorted(by: { $0.elapsed < $1.elapsed }) {
                let frame = interpolator.frame(at: marker.elapsed)
                var name: String
                if marker.kind == .sync {
                    syncCount += 1
                    name = "SYNC \(syncCount)"
                } else {
                    name = "MARK"
                }
                if let label = marker.label, !label.isEmpty { name += ": " + label }
                var wpt = "<wpt lat=\""
                wpt.appendFixed(frame.latitude, decimals: 7)
                wpt += "\" lon=\""
                wpt.appendFixed(frame.longitude, decimals: 7)
                wpt += "\"><ele>"
                wpt.appendFixed(frame.altitude, decimals: 2)
                wpt += "</ele><time>"
                wpt.appendISO8601(unixTime: marker.date.timeIntervalSince1970)
                wpt += "</time><name>\(name.xmlEscaped)</name></wpt>\n"
                try out.write(wpt)
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
            point += "</ds:hAcc></extensions></trkpt>\n"
            try out.write(point)
        }
        if inSegment { try out.write("</trkseg>\n") }
        try out.write("</trk>\n</gpx>\n")
        try out.close()
    }
}

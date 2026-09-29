import DriveDomain
import DriveReplay
import Foundation

/// The Vlog CSV: `VlogTrack` frames at a fixed rate, ready to line up with video (PLAN §5, §12).
///
/// `time_s` is zero at the first SYNC marker (or at session start when there is none) and negative before it;
/// `elapsed_s` is always seconds since session start; `utc` is the absolute time. Speed is km/h, lateral /
/// longitudinal / vertical g are in the vehicle frame (GPS-estimated lateral g when uncalibrated).
/// Numbers are fixed-decimal with `.` separators regardless of locale; non-finite values become empty fields.
public enum CSVExporter {
    public enum Rate: Sendable {
        case fps30
        case hz10

        public var framesPerSecond: Double {
            switch self {
            case .fps30: 30
            case .hz10: 10
            }
        }
    }

    public static let header =
        "time_s,elapsed_s,utc,latitude,longitude,speed_kmh,altitude_m,course_deg,lateral_g,longitudinal_g,"
        + "vertical_g,roll_deg,pitch_deg,gps_accuracy_m,has_fix"

    public static func export(reader: TelemetryReader, metadata: ExportMetadata, rate: Rate, to url: URL) throws {
        let track = VlogTrack(reader: reader, fps: rate.framesPerSecond, syncElapsed: metadata.syncElapsed)
        let startUnix = reader.clock.startedAt.timeIntervalSince1970
        let out = try BufferedFileWriter(url: url)
        try out.write(header + "\n")
        var line = ""
        for frame in track {
            let elapsed = frame.time + track.syncElapsed
            line.removeAll(keepingCapacity: true)
            line.appendFixed(frame.time, decimals: 3); line += ","
            line.appendFixed(elapsed, decimals: 3); line += ","
            line.appendISO8601(unixTime: startUnix + elapsed); line += ","
            line.appendFixed(frame.latitude, decimals: 7); line += ","
            line.appendFixed(frame.longitude, decimals: 7); line += ","
            line.appendFixed(Units.kmh(fromMetersPerSecond: frame.speed), decimals: 2); line += ","
            line.appendFixed(frame.altitude, decimals: 2); line += ","
            line.appendFixed(frame.course, decimals: 1); line += ","
            line.appendFixed(frame.lateralG, decimals: 3); line += ","
            line.appendFixed(frame.longitudinalG, decimals: 3); line += ","
            line.appendFixed(frame.verticalG, decimals: 3); line += ","
            line.appendFixed(frame.roll, decimals: 1); line += ","
            line.appendFixed(frame.pitch, decimals: 1); line += ","
            line.appendFixed(frame.gpsAccuracy, decimals: 1); line += ","
            line += frame.hasFix ? "1\n" : "0\n"
            try out.write(line)
        }
        try out.close()
    }
}

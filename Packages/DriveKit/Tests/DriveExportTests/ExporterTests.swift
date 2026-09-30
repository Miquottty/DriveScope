import DriveDomain
import DriveExport
import DriveRecording
import DriveReplay
import DriveSensors
import DriveStorage
import Foundation
import Testing

struct ExporterTests {
    private struct Fixture {
        let root: URL
        let files: SessionFiles
        let reader: TelemetryReader
        let summary: SessionSummary

        init(preset: CapturePreset, calibrated: Bool = true) async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeExport-\(UUID())")
            let built = try await ScriptedSessionBuilder.write(
                script: .akagi, preset: preset, duration: 90, root: root, calibrated: calibrated
            )
            files = SessionFiles(root: root, sessionID: built.manifest.sessionID)
            reader = try TelemetryReader(files: files)
            summary = built.summary
        }

        func metadata(title: String = "Akagi", markers: [ExportMarker] = [], sections: [DriveSection] = []) -> ExportMetadata {
            ExportMetadata(
                title: title, notes: "line1\nline2 \"q\"", places: [PlaceMeta(name: "Start", latitude: 36.5, longitude: 139.1, role: .start)],
                markers: markers, summary: summary, sections: sections
            )
        }

        func output(_ name: String) -> URL { root.appending(path: name) }
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    }

    /// PLAN §12: JSON is the lossless master — counts match the streams and Float fields survive bit-exactly.
    @Test func jsonIsLosslessMaster() async throws {
        let fx = try await Fixture(preset: .logger)
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let marker = ExportMarker(kind: .sync, elapsed: 10, date: fx.reader.clock.date(elapsed: 10), label: "clap \u{1F44F}")
        let corner = DriveSection(
            kind: .corner, start: 40, end: 43.5, distance: 52, direction: .left, peakLateralG: 0.31,
            entrySpeed: 14, exitSpeed: 12.5, minSpeed: 11
        )
        let climb = DriveSection(kind: .climb, start: 50, end: 80, distance: 600, altitudeChange: 36, averageGrade: 0.06)
        let url = fx.output("master.json")
        try JSONExporter.export(reader: fx.reader, metadata: fx.metadata(markers: [marker], sections: [corner, climb]), to: url)

        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["format"] as? String == "drivescope.session")
        let session = try #require(root["session"] as? [String: Any])
        #expect(session["notes"] as? String == "line1\nline2 \"q\"")
        #expect(session["preset"] as? String == "logger")
        #expect((session["calibration"] as? [String: Any])?["rotation"] is [Double])
        #expect(session["startedAt"] as? String == "2026-09-21T14:13:20.000Z")
        let markers = try #require(root["markers"] as? [[String: Any]])
        #expect(markers.first?["label"] as? String == "clap \u{1F44F}")
        // V1.1 sections: right after markers, every key present (null when it doesn't apply).
        let sections = try #require(root["sections"] as? [[String: Any]])
        #expect(sections.count == 2)
        #expect(sections[0]["kind"] as? String == "corner" && sections[0]["direction"] as? String == "left")
        #expect(sections[0]["peakLateralG"] as? Double == 0.31 && sections[0]["altitudeChange"] is NSNull)
        #expect(sections[1]["averageGrade"] as? Double == 0.06 && sections[1]["direction"] is NSNull)
        let text = try String(contentsOf: url, encoding: .utf8)
        let markersKey = try #require(text.range(of: "\"markers\":")), sectionsKey = try #require(text.range(of: "\"sections\":"))
        let eventsKey = try #require(text.range(of: "\"events\":"))
        #expect(markersKey.lowerBound < sectionsKey.lowerBound && sectionsKey.lowerBound < eventsKey.lowerBound)

        let location = try #require(root["location"] as? [String: Any])
        let rows = try #require(location["rows"] as? [[Double]])
        #expect(rows.count == StreamReader.recordCount(at: fx.files.url(for: .location), kind: .location))
        #expect(rows.count == fx.reader.locations.count)
        for (row, fix) in zip(rows, fx.reader.locations) {
            #expect(row[0] == fix.timestamp && row[1] == fix.latitude && row[2] == fix.longitude && row[4] == fix.receivedUptime)
            #expect(Float(row[5]).bitPattern == fix.speed.bitPattern)
            #expect(Float(row[6]).bitPattern == fix.course.bitPattern)
            #expect(Float(row[7]).bitPattern == fix.horizontalAccuracy.bitPattern)
            #expect(UInt32(row[11]) == fix.flags.rawValue)
        }
        let motion = try #require(root["motion"] as? [String: Any])
        #expect(motion["type"] as? String == "deviceMotion")
        let motionRows = try #require(motion["rows"] as? [[Double]])
        #expect(motionRows.count == StreamReader.recordCount(at: fx.files.url(for: .motion), kind: .motion))
        let sample = fx.reader.motion[123]
        #expect(Float(motionRows[123][1]).bitPattern == sample.userAcceleration.x.bitPattern)
        #expect(Float(motionRows[123][10]).bitPattern == sample.attitude.w.bitPattern)
        let altitude = try #require(root["altitude"] as? [String: Any])
        #expect((altitude["rows"] as? [Any])?.count == fx.reader.altitudes.count)

        // Eco stores accelerometer records; the type says so.
        let eco = try await Fixture(preset: .eco)
        defer { try? FileManager.default.removeItem(at: eco.root) }
        try JSONExporter.export(reader: eco.reader, metadata: eco.metadata(), to: eco.output("eco.json"))
        let ecoRoot = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: eco.output("eco.json"))) as? [String: Any])
        #expect((ecoRoot["motion"] as? [String: Any])?["type"] as? String == "accelerometer")

        let binary = fx.files.byteSize()
        print("EXPORT SIZES logger 90s: binary=\(binary) json=\(fx.size(url)) (\(Double(fx.size(url)) / Double(binary))x)")
    }

    /// The Vlog CSV lines up with video: a row at exactly t = 0 (SYNC between two frames of the session clock),
    /// POSIX numbers whatever the locale.
    @Test func csvIsAlignedToSyncAndLocaleIndependent() async throws {
        let fx = try await Fixture(preset: .logger)
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let sync = ExportMarker(kind: .sync, elapsed: 10.01, date: fx.reader.clock.date(elapsed: 10.01))
        let meta = fx.metadata(markers: [ExportMarker(kind: .mark, elapsed: 5, date: fx.reader.clock.date(elapsed: 5)), sync])
        let url = fx.output("vlog.csv")
        try CSVExporter.export(reader: fx.reader, metadata: meta, rate: .fps30, to: url)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines[0] == "time_s,elapsed_s,utc,latitude,longitude,speed_kmh,altitude_m,course_deg,lateral_g,longitudinal_g,vertical_g,roll_deg,pitch_deg,gps_accuracy_m,has_fix")
        #expect(lines.count - 1 == VlogTrack(reader: fx.reader, syncElapsed: 10.01).frameCount)
        let zero = try #require(lines.dropFirst().first { $0.hasPrefix("0.000,") })
        #expect(zero.split(separator: ",")[1] == "10.010")
        #expect(zero.split(separator: ",")[2] == "2026-09-21T14:13:30.010Z")
        #expect(lines[1].hasPrefix("-10.000,0.010,"))
        // '.' decimals only: a ',' decimal separator would change the field count.
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            #expect(fields.count == 15)
            #expect(fields[3].wholeMatch(of: /-?\d+\.\d{7}/) != nil)
        }

        try CSVExporter.export(reader: fx.reader, metadata: meta, rate: .hz10, to: fx.output("vlog10.csv"))
        let rows10 = try String(contentsOf: fx.output("vlog10.csv"), encoding: .utf8).split(separator: "\n").count - 1
        #expect(rows10 == VlogTrack(reader: fx.reader, fps: 10, syncElapsed: 10.01).frameCount)
        print("EXPORT SIZES logger 90s: csv30=\(fx.size(url)) csv10=\(fx.size(fx.output("vlog10.csv")))")
    }

    /// Parses a GPX file into what the assertions need: element texts by qualified name, in document order.
    private final class GPXCollector: NSObject, XMLParserDelegate {
        var texts: [String: [String]] = [:]
        var attributes: [String: [String: String]] = [:]
        /// Child element names of `<metadata>`, in order.
        var metadataChildren: [String] = []
        private var stack: [String] = []
        private var text = ""

        func numbers(_ name: String) -> [Double] { (texts[name] ?? []).compactMap(Double.init) }

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]) {
            if stack.last == "metadata" { metadataChildren.append(name) }
            stack.append(name)
            attributes[name] = attrs
            text = ""
        }
        func parser(_ p: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
            texts[name, default: []].append(text)
            text = ""
        }
    }

    private func parseGPX(_ url: URL) throws -> GPXCollector {
        let collector = GPXCollector()
        let parser = try #require(XMLParser(contentsOf: url))
        parser.delegate = collector
        #expect(parser.parse(), "\(String(describing: parser.parserError))")
        return collector
    }

    /// GPX must be well-formed XML even with hostile titles. It carries one point per valid fix with the 1-second G
    /// summaries (engine signs), barometric altitude and the Garmin extension, and waypoints — markers and sections —
    /// in time order, each typed.
    @Test func gpxIsWellFormedAndEscaped() async throws {
        let fx = try await Fixture(preset: .logger)
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let title = #"R&D <"Akagi"> 'run'"#
        // Out of order on purpose: SYNCs are numbered by time, not by list position, and waypoints are sorted by time.
        let markers = [
            ExportMarker(kind: .sync, elapsed: 60, date: fx.reader.clock.date(elapsed: 60)),
            ExportMarker(kind: .sync, elapsed: 10, date: fx.reader.clock.date(elapsed: 10)),
            ExportMarker(kind: .mark, elapsed: 40, date: fx.reader.clock.date(elapsed: 40), label: "a<b&c"),
        ]
        let sections = [
            DriveSection(kind: .stop, start: 70, end: 83.4, distance: 0, minSpeed: 0),
            DriveSection(kind: .corner, start: 40, end: 43.5, distance: 52, direction: .left, peakLateralG: 0.31),
            DriveSection(kind: .climb, start: 50, end: 80, distance: 600, altitudeChange: 36, averageGrade: 0.06),
        ]
        let url = fx.output("track.gpx")
        try GPXExporter.export(reader: fx.reader, metadata: fx.metadata(title: title, markers: markers, sections: sections), to: url)
        let gpx = try parseGPX(url)

        let fixes = fx.reader.locations.filter { $0.horizontalAccuracy > 0 }
        let valid = fixes.count
        #expect(gpx.texts["trkpt"]?.count == valid && valid > 0)
        #expect(gpx.texts["ds:hAcc"]?.count == valid && gpx.texts["ds:vAcc"]?.count == valid)
        #expect(gpx.texts["wpt"]?.count == 6)
        #expect(gpx.texts["name"] == [
            title, "SYNC 1", "MARK: a<b&c", "Corner 1 \u{B7} 0.31 G", "Climb 1 \u{B7} +36 m", "SYNC 2", "Stop 1 \u{B7} 13 s", title,
        ])
        #expect(gpx.texts["type"] == ["sync", "mark", "corner", "climb", "sync", "stop"])
        let wptTimes = try #require(gpx.texts["time"]).dropFirst().prefix(6)
        #expect(wptTimes.sorted() == Array(wptTimes))

        // The sign convention and G source are declared once, last in `<metadata>` (GPX 1.1 child order).
        #expect(gpx.metadataChildren == ["name", "desc", "time", "extensions"])
        #expect(gpx.attributes["ds:axes"] == ["lateral": "+left", "longitudinal": "+accelerating", "vertical": "+up"])
        #expect(gpx.texts["ds:gUnit"] == ["9.80665"] && gpx.texts["ds:gSource"] == ["motion"])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v2\""))

        // Every second of the scripted drive has motion G and a barometer reading; Garmin speed / course mirror ours.
        let lateral = gpx.numbers("ds:latG"), peak = gpx.numbers("ds:peakLatG"), longitudinal = gpx.numbers("ds:longG")
        #expect(lateral.count == valid && peak.count == valid && longitudinal.count == valid)
        #expect(gpx.numbers("ds:baroAlt").count == valid)
        #expect(gpx.texts["gpxtpx:TrackPointExtension"]?.count == valid)
        #expect(gpx.texts["gpxtpx:speed"] == gpx.texts["ds:speed"] && gpx.texts["gpxtpx:course"] == gpx.texts["ds:course"])
        #expect(zip(lateral, peak).allSatisfy { abs($0) <= abs($1) + 0.001 })

        // The means cover the 10 frames of the second around the fix (an independent pass over the same interpolator).
        let interpolator = TelemetryInterpolator(reader: fx.reader, options: .init(speedWindow: 1, gWindow: 0.1, speedFusion: false))
        let k = valid / 2
        let t = fx.reader.clock.elapsed(unixTime: fixes[k].timestamp)
        let frames = (Int((t * 10 - 5).rounded(.up))..<Int((t * 10 + 5).rounded(.up))).map { interpolator.frame(at: Double($0) / 10) }
        #expect(frames.count == 10 && frames.allSatisfy(\.hasMotionG))
        #expect(abs(lateral[k] - frames.map(\.lateralG).reduce(0, +) / 10) < 0.001)
        #expect(abs(longitudinal[k] - frames.map(\.longitudinalG).reduce(0, +) / 10) < 0.001)
        let expectedPeak = try #require(frames.map(\.lateralG).max { abs($0) < abs($1) })
        #expect(abs(peak[k] - expectedPeak) < 0.001)

        // Engine signs: the hardest longitudinal point is where the speed changes the way its sign says (+ = accelerating).
        let hardest = try #require(longitudinal.indices.max { abs(longitudinal[$0]) < abs(longitudinal[$1]) })
        let dv = fixes[min(hardest + 2, valid - 1)].speed - fixes[max(hardest - 2, 0)].speed
        #expect(abs(dv) > 1 && (dv > 0) == (longitudinal[hardest] > 0))
        print("EXPORT SIZES logger 90s: gpx=\(fx.size(url))")
    }

    /// Without calibration only the GPS-estimated lateral g exists: the file says so and invents no longitudinal value
    /// (the frame's 0 would pass for a measurement).
    @Test func gpxDeclaresGpsEstimatedLateralG() async throws {
        let fx = try await Fixture(preset: .logger, calibrated: false)
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let url = fx.output("uncalibrated.gpx")
        try GPXExporter.export(reader: fx.reader, metadata: fx.metadata(), to: url)
        let gpx = try parseGPX(url)
        #expect(gpx.texts["ds:gSource"] == ["gps-estimate"])
        #expect(!gpx.numbers("ds:latG").isEmpty && gpx.numbers("ds:longG").isEmpty)
        #expect(gpx.numbers("ds:peakLatG").count == gpx.numbers("ds:latG").count)
    }
}

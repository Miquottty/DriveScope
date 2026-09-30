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

        init(preset: CapturePreset) async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "DriveScopeExport-\(UUID())")
            let built = try await ScriptedSessionBuilder.write(script: .akagi, preset: preset, duration: 90, root: root)
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

    /// GPX must be well-formed XML even with hostile titles, and carry one point per valid fix plus a waypoint per marker.
    @Test func gpxIsWellFormedAndEscaped() async throws {
        let fx = try await Fixture(preset: .logger)
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let title = #"R&D <"Akagi"> 'run'"#
        // Out of order on purpose: SYNCs are numbered by time, not by list position.
        let markers = [
            ExportMarker(kind: .sync, elapsed: 60, date: fx.reader.clock.date(elapsed: 60)),
            ExportMarker(kind: .sync, elapsed: 10, date: fx.reader.clock.date(elapsed: 10)),
            ExportMarker(kind: .mark, elapsed: 40, date: fx.reader.clock.date(elapsed: 40), label: "a<b&c"),
        ]
        let url = fx.output("track.gpx")
        try GPXExporter.export(reader: fx.reader, metadata: fx.metadata(title: title, markers: markers), to: url)

        final class Counter: NSObject, XMLParserDelegate {
            var trkpt = 0, wpt = 0, hAcc = 0
            var names: [String] = []
            private var text = ""
            func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                switch name {
                case "trkpt": trkpt += 1
                case "wpt": wpt += 1
                case "ds:hAcc": hAcc += 1
                default: break
                }
                text = ""
            }
            func parser(_ p: XMLParser, foundCharacters string: String) { text += string }
            func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                if name == "name" { names.append(text) }
            }
        }
        let counter = Counter()
        let parser = try #require(XMLParser(contentsOf: url))
        parser.delegate = counter
        #expect(parser.parse(), "\(String(describing: parser.parserError))")
        let valid = fx.reader.locations.filter { $0.horizontalAccuracy > 0 }.count
        #expect(counter.trkpt == valid && counter.hAcc == valid && valid > 0)
        #expect(counter.wpt == 3)
        #expect(counter.names == [title, "SYNC 1", "MARK: a<b&c", "SYNC 2", title])
        print("EXPORT SIZES logger 90s: gpx=\(fx.size(url))")
    }
}

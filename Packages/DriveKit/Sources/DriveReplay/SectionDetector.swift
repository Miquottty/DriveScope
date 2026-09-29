import DriveDomain
import DriveStorage
import Foundation

/// Finds corners, climbs / descents and stops in a recorded drive (PLAN §12, V1.1). Pure: the same streams and
/// parameters always give the same sections, so stored results are recomputed only when `version` changes.
public enum SectionDetector {
    /// Bump when thresholds or logic change: stored sections older than this are recomputed lazily.
    public static let version = 1

    public struct Parameters: Sendable {
        /// Frame rate of the analysis pass.
        public var rate: Double = 5
        /// A corner starts at this |lateral g| and continues while it stays above `cornerHold` with the same sign.
        public var cornerEnter = 0.15
        public var cornerHold = 0.08
        public var cornerMinDuration: TimeInterval = 1.5
        /// m/s at the peak (15 km/h): parking-lot turns are not corners.
        public var cornerMinSpeed = 4.2
        /// Degrees of heading change over the corner.
        public var cornerMinTurn = 15.0
        /// Same-direction corners closer than this merge (a wobble in the middle of one bend).
        public var cornerMergeGap: TimeInterval = 1
        /// A stop is GPS speed below this (1 km/h) for at least `stopMinDuration`.
        public var stopSpeed = 0.28
        public var stopMinDuration: TimeInterval = 10
        /// Longest fix interval still counted as continuous (a GPS gap is never a stop).
        public var stopMaxFixGap: TimeInterval = 5
        /// Altitude profile resolution and the trailing distance the grade is measured over.
        public var gradeBin = 50.0
        public var gradeSpan = 200.0
        public var gradeMin = 0.03
        public var climbMinLength = 500.0
        public var climbMinChange = 15.0

        public init() {}
    }

    /// One analysis frame; `distance` is cumulative metres.
    public struct Sample: Sendable {
        public var time: TimeInterval
        public var lateralG: Double
        /// m/s.
        public var speed: Double
        /// Compass degrees.
        public var course: Double
        public var distance: Double
        public var altitude: Double

        public init(time: TimeInterval, lateralG: Double, speed: Double, course: Double, distance: Double, altitude: Double) {
            self.time = time
            self.lateralG = lateralG
            self.speed = speed
            self.course = course
            self.distance = distance
            self.altitude = altitude
        }
    }

    public static func detect(
        reader: TelemetryReader, calibration: MountCalibration?, parameters: Parameters = Parameters()
    ) -> [DriveSection] {
        let samples = analysisSamples(reader: reader, calibration: calibration, rate: parameters.rate)
        let sections = corners(samples, parameters: parameters)
            + stops(reader: reader, parameters: parameters)
            + grades(samples, parameters: parameters)
        return sections.sorted { $0.start < $1.start }
    }

    /// Frames at `rate` Hz with lightly smoothed speed and G (the detector wants shape, not display smoothness).
    static func analysisSamples(reader: TelemetryReader, calibration: MountCalibration?, rate: Double) -> [Sample] {
        guard !reader.locations.isEmpty, reader.duration > 0 else { return [] }
        let interpolator = TelemetryInterpolator(
            reader: reader, calibration: calibration, options: .init(speedWindow: 3, gWindow: 0.5)
        )
        var samples: [Sample] = []
        samples.reserveCapacity(Int(reader.duration * rate) + 1)
        var distance = 0.0
        var previous: ReplayTelemetryFrame?
        for i in 0...Int(reader.duration * rate) {
            let frame = interpolator.frame(at: Double(i) / rate)
            if let previous {
                distance += Units.distance(lat1: previous.latitude, lon1: previous.longitude, lat2: frame.latitude, lon2: frame.longitude)
            }
            previous = frame
            samples.append(Sample(
                time: frame.time, lateralG: frame.lateralG, speed: frame.speed, course: frame.course,
                distance: distance, altitude: frame.altitude
            ))
        }
        return samples
    }

    // MARK: - Corners

    /// Hysteresis on lateral g (+ = left). Public so a test can run the same rule on ground truth.
    public static func corners(_ samples: [Sample], parameters: Parameters = Parameters()) -> [DriveSection] {
        var runs: [ClosedRange<Int>] = []
        var i = 0
        while i < samples.count {
            guard abs(samples[i].lateralG) >= parameters.cornerEnter else { i += 1; continue }
            let sign = samples[i].lateralG.sign
            func holds(_ k: Int) -> Bool { samples[k].lateralG.sign == sign && abs(samples[k].lateralG) >= parameters.cornerHold }
            var start = i
            while start > 0, holds(start - 1) { start -= 1 }
            var end = i
            while end + 1 < samples.count, holds(end + 1) { end += 1 }
            if let last = runs.last, samples[last.lowerBound].lateralG.sign == sign,
               samples[start].time - samples[last.upperBound].time < parameters.cornerMergeGap {
                runs[runs.count - 1] = last.lowerBound...end
            } else {
                runs.append(start...end)
            }
            i = end + 1
        }
        return runs.compactMap { range in
            let slice = samples[range]
            guard let first = slice.first, let last = slice.last,
                  last.time - first.time >= parameters.cornerMinDuration,
                  let peak = slice.max(by: { abs($0.lateralG) < abs($1.lateralG) }),
                  peak.speed >= parameters.cornerMinSpeed else { return nil }
            var turn = 0.0
            for k in range.dropFirst() {
                turn += Units.headingDelta(from: samples[k - 1].course, to: samples[k].course)
            }
            guard abs(turn) >= parameters.cornerMinTurn else { return nil }
            return DriveSection(
                kind: .corner, start: first.time, end: last.time, distance: last.distance - first.distance,
                direction: peak.lateralG > 0 ? .left : .right, peakLateralG: abs(peak.lateralG),
                entrySpeed: first.speed, exitSpeed: last.speed, minSpeed: slice.map(\.speed).min()
            )
        }
    }

    // MARK: - Stops

    /// From the fixes themselves: interpolated speed would invent stops inside GPS gaps.
    static func stops(reader: TelemetryReader, parameters: Parameters) -> [DriveSection] {
        let clock = reader.clock
        var sections: [DriveSection] = []
        var runStart: TimeInterval?
        var runEnd: TimeInterval = 0
        func close() {
            if let start = runStart, runEnd - start >= parameters.stopMinDuration {
                sections.append(DriveSection(kind: .stop, start: start, end: runEnd, distance: 0, minSpeed: 0))
            }
            runStart = nil
        }
        for fix in reader.locations {
            let t = clock.elapsed(unixTime: fix.timestamp)
            let stopped = fix.hasValidSpeed && Double(fix.speed) < parameters.stopSpeed
            if runStart != nil, t - runEnd > parameters.stopMaxFixGap { close() }
            if stopped {
                if runStart == nil { runStart = t }
                runEnd = t
            } else {
                close()
            }
        }
        close()
        return sections
    }

    // MARK: - Climbs / descents

    /// Altitude resampled every `gradeBin` metres driven (a stop adds no bins), smoothed over 3 bins; a climb is a
    /// run of bins whose trailing `gradeSpan` grade stays ≥ `gradeMin` (descent: ≤ −`gradeMin`).
    static func grades(_ samples: [Sample], parameters: Parameters) -> [DriveSection] {
        guard let total = samples.last?.distance, total >= parameters.climbMinLength else { return [] }
        var bins: [(time: TimeInterval, distance: Double, altitude: Double)] = []
        var k = 0
        var target = 0.0
        while target <= total {
            while k + 1 < samples.count, samples[k + 1].distance < target { k += 1 }
            let a = samples[k], b = samples[min(k + 1, samples.count - 1)]
            let f = b.distance > a.distance ? min(max((target - a.distance) / (b.distance - a.distance), 0), 1) : 0
            bins.append((a.time + (b.time - a.time) * f, target, a.altitude + (b.altitude - a.altitude) * f))
            target += parameters.gradeBin
        }
        let smoothed = bins.indices.map { i in
            let range = max(0, i - 1)...min(bins.count - 1, i + 1)
            return range.reduce(0) { $0 + bins[$1].altitude } / Double(range.count)
        }
        let lag = max(1, Int((parameters.gradeSpan / parameters.gradeBin).rounded()))
        func trend(_ i: Int) -> Int {
            guard i >= lag else { return 0 }
            let grade = (smoothed[i] - smoothed[i - lag]) / (bins[i].distance - bins[i - lag].distance)
            return grade >= parameters.gradeMin ? 1 : grade <= -parameters.gradeMin ? -1 : 0
        }
        var sections: [DriveSection] = []
        var i = lag
        var previousEnd = 0
        while i < bins.count {
            let direction = trend(i)
            guard direction != 0 else { i += 1; continue }
            var end = i
            while end + 1 < bins.count, trend(end + 1) == direction { end += 1 }
            // The first rising bin measured the grade over the `lag` bins before it: the section starts there
            // (but never inside the previous section).
            let start = max(i - lag, previousEnd)
            previousEnd = end
            let length = bins[end].distance - bins[start].distance
            let change = smoothed[end] - smoothed[start]
            if length >= parameters.climbMinLength, abs(change) >= parameters.climbMinChange {
                sections.append(DriveSection(
                    kind: direction > 0 ? .climb : .descent, start: bins[start].time, end: bins[end].time,
                    distance: length, altitudeChange: change, averageGrade: change / length
                ))
            }
            i = end + 1
        }
        return sections
    }
}

import Foundation

/// A stretch of a drive found by section analysis (PLAN §12, V1.1): a corner, a climb / descent, or a stop.
/// Derived data — recomputable from the raw streams at any time (PLAN §18).
/// Named `DriveSection` so it never collides with SwiftUI's `Section`.
public struct DriveSection: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case corner
        case climb
        case descent
        case stop
    }

    public enum Direction: String, Sendable, Codable {
        case left
        case right
    }

    public var kind: Kind
    /// Session elapsed, seconds.
    public var start: TimeInterval
    public var end: TimeInterval
    /// Metres driven within the section (0 for a stop).
    public var distance: Double

    // Corner
    public var direction: Direction?
    /// Peak |lateral g| (vehicle frame when calibrated, GPS-estimated otherwise).
    public var peakLateralG: Double?
    /// m/s.
    public var entrySpeed: Double?
    public var exitSpeed: Double?
    public var minSpeed: Double?

    // Climb / descent
    /// Metres; + up.
    public var altitudeChange: Double?
    /// altitudeChange / distance (0.05 = 5 %).
    public var averageGrade: Double?

    public init(
        kind: Kind, start: TimeInterval, end: TimeInterval, distance: Double,
        direction: Direction? = nil, peakLateralG: Double? = nil,
        entrySpeed: Double? = nil, exitSpeed: Double? = nil, minSpeed: Double? = nil,
        altitudeChange: Double? = nil, averageGrade: Double? = nil
    ) {
        self.kind = kind
        self.start = start
        self.end = end
        self.distance = distance
        self.direction = direction
        self.peakLateralG = peakLateralG
        self.entrySpeed = entrySpeed
        self.exitSpeed = exitSpeed
        self.minSpeed = minSpeed
        self.altitudeChange = altitudeChange
        self.averageGrade = averageGrade
    }

    public var id: String { "\(kind.rawValue)@\(start)" }
    public var duration: TimeInterval { end - start }
}

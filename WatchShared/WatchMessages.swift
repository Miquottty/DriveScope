import Foundation

// iPhone ↔ Apple Watch messages (PLAN §19 W3). Compiled into both the app and the watch app (the watch app links
// no packages). Each travels as JSON `Data` under one key, since WatchConnectivity carries property lists.

/// What the watch shows. Sent on every phase change (application context) and at 1 Hz while recording.
nonisolated struct WatchState: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        case idle
        case recording
        /// STOP pressed; files are being finalized.
        case saving
    }

    var phase: Phase
    /// Wall-clock instant at which elapsed was 0; the watch ticks its own clock from it.
    var timerStart: Date
    var speedKmh: Double?
    var markCount: Int
    var gpsSearching: Bool
    /// START is offered on the watch (robust mode on, Always permission, idle).
    var canStart: Bool
    /// In-app language of the iPhone (PLAN §13), so the watch follows it.
    var languageCode: String

    static let key = "state"
}

nonisolated struct WatchCommand: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case mark
        case stop
        case start
    }

    /// Duplicate deliveries of one press are dropped by id.
    var id: UUID
    var kind: Kind
    /// When the wrist pressed; stored with the marker next to the iPhone's receive time.
    var pressedAt: Date

    static let key = "command"
}

nonisolated struct WatchAck: Codable, Sendable, Equatable {
    var id: UUID
    var accepted: Bool
    var markCount: Int

    static let key = "ack"
}

nonisolated enum WatchCoding {
    static func encode<T: Encodable>(_ value: T, key: String) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value) else { return [:] }
        return [key: data]
    }

    static func decode<T: Decodable>(_ type: T.Type, key: String, from message: [String: Any]) -> T? {
        guard let data = message[key] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

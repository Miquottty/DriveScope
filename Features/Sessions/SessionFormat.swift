import DriveDomain
import DriveStorage
import Foundation

/// A number with its unit, so views can style the unit separately (Detail metric tiles).
struct Quantity {
    var value: String
    var unit: String

    var text: String { unit.isEmpty ? value : "\(value)\u{00A0}\(unit)" }
}

/// Locale-aware formatting of session values for lists and detail. Numbers use the in-app language's locale;
/// units keep their fixed symbols (km, km/h, m) until the Settings unit switch arrives.
struct SessionFormat {
    let language: AppLanguage

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let gregorian = Calendar(identifier: .gregorian)

    private var locale: Locale { language.locale }

    // MARK: Quantities

    func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    func distance(meters: Double) -> Quantity {
        let km = Measurement(value: meters, unit: UnitLength.meters).converted(to: .kilometers)
        return Quantity(value: number(km.value, fraction: 1), unit: UnitLength.kilometers.symbol)
    }

    func speed(metersPerSecond: Double) -> Quantity {
        let kmh = Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond).converted(to: .kilometersPerHour)
        return Quantity(value: number(kmh.value, fraction: 0), unit: UnitSpeed.kilometersPerHour.symbol)
    }

    func elevationGain(meters: Double) -> Quantity {
        Quantity(value: "+" + number(meters, fraction: 0), unit: UnitLength.meters.symbol)
    }

    func meters(_ value: Double, fraction: Int = 1) -> Quantity {
        Quantity(value: number(value, fraction: fraction), unit: UnitLength.meters.symbol)
    }

    func seconds(_ value: Double) -> Quantity {
        Quantity(value: number(value, fraction: 1), unit: UnitDuration.seconds.symbol)
    }

    func number(_ value: Double, fraction: Int) -> String {
        value.formatted(.number.precision(.fractionLength(fraction)).locale(locale))
    }

    func integer(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    func percent(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(1)).locale(locale)) + " %"
    }

    // MARK: Dates (in the session's own time zone)

    private func zone(_ session: DriveSession) -> TimeZone {
        TimeZone(identifier: session.timeZoneID) ?? .current
    }

    /// "06:12" — 24-hour, like the mock, in every locale.
    func clockTime(_ date: Date, in zone: TimeZone) -> String {
        date.formatted(
            Date.VerbatimFormatStyle(
                format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                locale: Self.posix, timeZone: zone, calendar: Self.gregorian
            )
        )
    }

    private func monthDay(_ date: Date, in zone: TimeZone) -> String {
        date.formatted(
            Date.FormatStyle(locale: locale, calendar: Self.gregorian, timeZone: zone).month(.abbreviated).day()
        )
    }

    /// "Sep 28"
    func shortDate(_ session: DriveSession) -> String {
        monthDay(session.startedAt, in: zone(session))
    }

    /// "Sun, Sep 28 · 06:12"
    func dateLine(_ session: DriveSession) -> String {
        let zone = zone(session)
        let day = session.startedAt.formatted(
            Date.FormatStyle(locale: locale, calendar: Self.gregorian, timeZone: zone)
                .weekday(.abbreviated).month(.abbreviated).day()
        )
        return "\(day) · \(clockTime(session.startedAt, in: zone))"
    }

    /// "Sun, Sep 28 · 06:12 – 06:54"
    func dateRangeLine(_ session: DriveSession) -> String {
        guard let end = session.endedAt else { return dateLine(session) }
        return "\(dateLine(session)) – \(clockTime(end, in: zone(session)))"
    }

    /// Title, or "Sep 29 14:05" until the finalizer / user names the session.
    func title(_ session: DriveSession) -> String {
        if !session.title.isEmpty { return session.title }
        let zone = zone(session)
        return "\(monthDay(session.startedAt, in: zone)) \(clockTime(session.startedAt, in: zone))"
    }

    /// "yyyy-MM" section key → "September 2026" / "2026年9月".
    func monthTitle(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Self.posix
        parser.calendar = Self.gregorian
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM"
        guard let date = parser.date(from: key) else { return language.string("Earlier") }
        return date.formatted(
            Date.FormatStyle(locale: locale, calendar: Self.gregorian, timeZone: TimeZone(secondsFromGMT: 0)!)
                .year().month(.wide)
        )
    }

    // MARK: Lines

    /// "42:31 · 36.7 km · max 103 · +842 m · 2 marks"
    func metaLine(_ session: DriveSession) -> String {
        var parts = [
            duration(session.duration),
            distance(meters: session.distance).text,
            language.string("max \(speed(metersPerSecond: session.maxSpeed).value)"),
        ]
        if session.elevationGain >= 10 { parts.append(elevationGain(meters: session.elevationGain).text) }
        let marks = session.markers.filter { $0.kind == .mark }.count
        if marks > 0 { parts.append(language.string("\(marks) marks")) }
        return parts.joined(separator: " · ")
    }
}

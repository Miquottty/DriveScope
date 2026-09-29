import Foundation

// Locale-independent text primitives shared by the exporters. Everything is hand-rolled so output is
// byte-identical regardless of the device's region settings (`,` decimal separators, other calendars).

extension String {
    /// Fixed-decimal number with `.` as the separator. Non-finite values append nothing (empty CSV field).
    mutating func appendFixed(_ value: Double, decimals: Int) {
        guard value.isFinite else { return }
        let scale = Self.powersOfTen[decimals]
        let scaled = (abs(value) * Double(scale)).rounded()
        guard scaled < 9e18 else {
            append(value.description)
            return
        }
        let n = UInt64(scaled)
        if value < 0, n != 0 { append("-") }
        append(String(n / scale))
        guard decimals > 0 else { return }
        append(".")
        let fraction = String(n % scale)
        append(String(repeating: "0", count: decimals - fraction.count))
        append(fraction)
    }

    /// `2026-09-29T12:34:56.789Z` (UTC, millisecond precision).
    mutating func appendISO8601(unixTime: Double) {
        guard unixTime.isFinite else { return }
        let totalMs = Int64((unixTime * 1000).rounded())
        let days = Self.floorDiv(totalMs, 86_400_000)
        let msOfDay = totalMs - days * 86_400_000
        // Civil-from-days (Howard Hinnant), proleptic Gregorian.
        let z = days + 719_468
        let era = Self.floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        func pad(_ v: Int64, _ width: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        append("\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T")
        append("\(pad(msOfDay / 3_600_000, 2)):\(pad(msOfDay / 60_000 % 60, 2)):\(pad(msOfDay / 1000 % 60, 2)).\(pad(msOfDay % 1000, 3))Z")
    }

    private static let powersOfTen: [UInt64] = [1, 10, 100, 1000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000]

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}

extension String {
    /// JSON number, shortest round-trip form. Non-finite values become `null` (JSON has no NaN / Infinity).
    mutating func appendJSON(_ value: Double) {
        append(value.isFinite ? value.description : "null")
    }

    /// Uses `Float.description` directly: widening to Double first would print noise digits (0.1f → 0.10000000149…).
    mutating func appendJSON(_ value: Float) {
        append(value.isFinite ? value.description : "null")
    }

    mutating func appendJSON(_ value: String?) {
        guard let value else {
            append("null")
            return
        }
        append("\"")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": append("\\\"")
            case "\\": append("\\\\")
            case "\n": append("\\n")
            case "\r": append("\\r")
            case "\t": append("\\t")
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                append("\\u" + String(repeating: "0", count: 4 - hex.count) + hex)
            default: unicodeScalars.append(scalar)
            }
        }
        append("\"")
    }

    mutating func appendJSONDate(_ unixTime: Double) {
        append("\"")
        appendISO8601(unixTime: unixTime)
        append("\"")
    }

    /// XML 1.0 text / attribute escaping. Characters XML cannot carry at all (most C0 controls) are dropped.
    var xmlEscaped: String {
        var out = ""
        out.reserveCapacity(utf8.count)
        for scalar in unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF: break
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

/// Comma-separated JSON array body (`1,2.5,null`) built without intermediate arrays.
struct JSONRow {
    private(set) var text = ""
    private var first = true

    mutating func reset() {
        text.removeAll(keepingCapacity: true)
        first = true
    }

    private mutating func separate() {
        if first { first = false } else { text += "," }
    }

    mutating func add(_ v: Double) { separate(); text.appendJSON(v) }
    mutating func add(_ v: Float) { separate(); text.appendJSON(v) }
    mutating func add<I: BinaryInteger>(_ v: I) { separate(); text += String(v) }
}

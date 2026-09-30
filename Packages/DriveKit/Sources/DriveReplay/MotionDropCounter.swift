/// Counts motion samples that never arrived, from the gaps between consecutive timestamps.
/// iOS delivers "50 Hz" device motion at ~49.76 Hz, perfectly regular — measuring against `nominalHz` over the
/// whole span would report that as 0.5 % loss. Only a gap well past one nominal interval is a drop.
/// Live statistics and the Quality screen both use this, so the two agree.
struct MotionDropCounter: Sendable {
    let nominalHz: Double
    private(set) var received = 0
    private(set) var missing = 0
    private var last: Double?

    init(nominalHz: Double) {
        self.nominalHz = nominalHz
    }

    mutating func add(timestamp: Double) {
        received += 1
        defer { last = timestamp }
        guard nominalHz > 0, let previous = last else { return }
        let dt = timestamp - previous
        // A corrupt timestamp must not overflow the conversion.
        if dt.isFinite, dt > 1.5 / nominalHz { missing += max(0, Int(min(dt * nominalHz, 1e9).rounded()) - 1) }
    }

    /// Fraction of expected samples that are missing, 0…1.
    var rate: Double {
        received + missing > 0 ? Double(missing) / Double(received + missing) : 0
    }
}

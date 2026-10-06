import DriveDomain
import Foundation

/// Plays the device's slow satellite lock (`-SatelliteDelay`, tests): for the first `delay` seconds of iteration
/// every fix becomes what Core Location delivers before the lock — a Wi‑Fi / cell position without speed or
/// course, ±40 m (seen on a real start under a roof for 6 minutes).
public struct CoarseStartLocationSource: LocationSource {
    let inner: any LocationSource
    let clock: any TelemetryClock
    let delay: TimeInterval

    public init(inner: any LocationSource, clock: any TelemetryClock, delay: TimeInterval) {
        self.inner = inner
        self.clock = clock
        self.delay = delay
    }

    public func locations() -> AsyncStream<LocationSample> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let start = clock.uptime
            let task = Task {
                for await location in inner.locations() {
                    guard clock.uptime - start < delay else {
                        continuation.yield(location)
                        continue
                    }
                    var coarse = location
                    coarse.speed = -1
                    coarse.course = -1
                    coarse.speedAccuracy = -1
                    coarse.courseAccuracy = -1
                    coarse.horizontalAccuracy = 40
                    continuation.yield(coarse)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

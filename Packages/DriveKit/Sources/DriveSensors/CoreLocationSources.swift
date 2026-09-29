#if os(iOS)
import CoreLocation
import DriveDomain
import Foundation
import Synchronization

extension LocationSample {
    init(_ location: CLLocation, receivedUptime: TimeInterval) {
        var flags: Flags = []
        if let info = location.sourceInformation {
            if info.isSimulatedBySoftware { flags.insert(.simulatedBySoftware) }
            if info.isProducedByAccessory { flags.insert(.producedByAccessory) }
        }
        self.init(
            timestamp: location.timestamp.timeIntervalSince1970,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            receivedUptime: receivedUptime,
            speed: Float(location.speed),
            course: Float(location.course),
            horizontalAccuracy: Float(location.horizontalAccuracy),
            verticalAccuracy: Float(location.verticalAccuracy),
            speedAccuracy: Float(location.speedAccuracy),
            courseAccuracy: Float(location.courseAccuracy),
            flags: flags
        )
    }
}

/// `CLLocationManager` backend (PLAN §2.1). The manager lives on the main run loop; at ~1 Hz that is negligible.
public final class CLLocationManagerSource: NSObject, LocationSource, CLLocationManagerDelegate, @unchecked Sendable {
    // Only touched on the main actor.
    private var manager: CLLocationManager?
    private let continuation = Mutex<AsyncStream<LocationSample>.Continuation?>(nil)

    override public init() {}

    public func locations() -> AsyncStream<LocationSample> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            self.continuation.withLock { $0 = continuation }
            Task { @MainActor in self.start() }
            continuation.onTermination = { _ in
                Task { @MainActor in self.stop() }
            }
        }
    }

    @MainActor private func start() {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        self.manager = manager
    }

    @MainActor private func stop() {
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let uptime = ProcessInfo.processInfo.systemUptime
        continuation.withLock { continuation in
            for location in locations { continuation?.yield(LocationSample(location, receivedUptime: uptime)) }
        }
    }
}

/// `CLLocationUpdate.liveUpdates` backend with a background activity session (PLAN §2.1, compared in Test B).
public struct LiveUpdatesLocationSource: LocationSource {
    /// Robust mode (V1.1): the session declares Always, so updates may start after a background relaunch.
    private let always: Bool

    public init(always: Bool = false) {
        self.always = always
    }

    public func locations() -> AsyncStream<LocationSample> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                let background = CLBackgroundActivitySession()
                let service = CLServiceSession(authorization: always ? .always : .whenInUse, fullAccuracyPurposeKey: "DriveTelemetry")
                defer {
                    background.invalidate()
                    service.invalidate()
                }
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                        guard let location = update.location else { continue }
                        continuation.yield(LocationSample(location, receivedUptime: ProcessInfo.processInfo.systemUptime))
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif

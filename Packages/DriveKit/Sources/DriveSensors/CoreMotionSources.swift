#if os(iOS)
import CoreMotion
import DriveDomain
import Foundation

/// `CMMotionManager` on a private serial queue — samples never touch the main actor (PLAN §2.2).
public final class CoreMotionSource: MotionSource, @unchecked Sendable {
    // CMMotionManager is not Sendable; it is only used from `start`/`stop`, serialized by `queue`.
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "DriveScope.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    public let referenceFrame: CMAttitudeReferenceFrame

    public init(referenceFrame: CMAttitudeReferenceFrame = .xArbitraryCorrectedZVertical) {
        self.referenceFrame = referenceFrame
    }

    public func isAvailable(_ mode: CapturePreset.MotionMode) -> Bool {
        switch mode {
        case .none: true
        case .accelerometer: manager.isAccelerometerAvailable
        case .deviceMotion: manager.isDeviceMotionAvailable
        }
    }

    public func samples(mode: CapturePreset.MotionMode) -> AsyncStream<MotionEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(4096)) { continuation in
            switch mode {
            case .none:
                continuation.finish()
                return
            case .accelerometer(let hz):
                manager.accelerometerUpdateInterval = 1 / hz
                manager.startAccelerometerUpdates(to: queue) { data, _ in
                    guard let data else { return }
                    let a = data.acceleration
                    continuation.yield(.acceleration(AccelSample(
                        timestamp: data.timestamp, acceleration: Vector3(x: Float(a.x), y: Float(a.y), z: Float(a.z))
                    )))
                }
            case .deviceMotion(let hz):
                manager.deviceMotionUpdateInterval = 1 / hz
                manager.showsDeviceMovementDisplay = false
                manager.startDeviceMotionUpdates(using: referenceFrame, to: queue) { motion, _ in
                    guard let motion else { return }
                    continuation.yield(.deviceMotion(MotionSample(motion)))
                }
            }
            continuation.onTermination = { _ in
                self.manager.stopAccelerometerUpdates()
                self.manager.stopDeviceMotionUpdates()
            }
        }
    }
}

extension MotionSample {
    init(_ m: CMDeviceMotion) {
        func v(_ x: Double, _ y: Double, _ z: Double) -> Vector3 { Vector3(x: Float(x), y: Float(y), z: Float(z)) }
        let q = m.attitude.quaternion
        self.init(
            timestamp: m.timestamp,
            userAcceleration: v(m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z),
            gravity: v(m.gravity.x, m.gravity.y, m.gravity.z),
            rotationRate: v(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z),
            attitude: Quaternion(w: Float(q.w), x: Float(q.x), y: Float(q.y), z: Float(q.z)),
            magneticField: v(m.magneticField.field.x, m.magneticField.field.y, m.magneticField.field.z),
            magneticAccuracy: m.magneticField.accuracy.rawValue
        )
    }
}

/// `CMAltimeter` relative altitude + pressure (PLAN §2.3).
public final class CoreAltimeterSource: AltimeterSource, @unchecked Sendable {
    private let altimeter = CMAltimeter()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "DriveScope.altimeter"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    public init() {}

    public var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    public func altitudes() -> AsyncStream<AltitudeSample> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            altimeter.startRelativeAltitudeUpdates(to: queue) { data, _ in
                guard let data else { return }
                continuation.yield(AltitudeSample(
                    timestamp: data.timestamp,
                    relativeAltitude: data.relativeAltitude.floatValue,
                    pressure: data.pressure.floatValue
                ))
            }
            continuation.onTermination = { _ in self.altimeter.stopRelativeAltitudeUpdates() }
        }
    }
}
#endif

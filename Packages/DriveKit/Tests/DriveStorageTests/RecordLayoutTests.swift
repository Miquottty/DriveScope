import DriveDomain
import Testing

struct RecordLayoutTests {
    @Test func recordsRoundTripAtDeclaredSize() {
        let location = LocationSample(
            timestamp: 1_790_000_000.25, latitude: 36.389, longitude: 139.061, altitude: 112.5, receivedUptime: 4242.5,
            speed: 16.7, course: 271.5, horizontalAccuracy: 4.2, verticalAccuracy: 3.1, speedAccuracy: 0.4,
            courseAccuracy: 5, flags: [.synthetic]
        )
        let motion = MotionSample(
            timestamp: 4242.51, userAcceleration: Vector3(x: 0.1, y: -0.2, z: 0.03), gravity: Vector3(x: 0, y: -1, z: 0),
            rotationRate: Vector3(x: 0.01, y: 0.02, z: 0.3), attitude: Quaternion(w: 0.7, x: 0.1, y: 0.1, z: 0.7),
            magneticField: Vector3(x: 20, y: -5, z: 40), magneticAccuracy: 2
        )
        let event = EventRecord(kind: .batterySnapshot, source: .watch, aux: 2, elapsed: 300, value: 0.83)

        #expect(location.encoded().count == 72)
        #expect(motion.encoded().count == 76)
        #expect(AccelSample(timestamp: 1, acceleration: .zero).encoded().count == 20)
        #expect(AltitudeSample(timestamp: 1, relativeAltitude: 2, pressure: 101.3).encoded().count == 16)
        #expect(event.encoded().count == 24)

        #expect(location.encoded().withUnsafeBytes { LocationSample(decoding: $0, at: 0) } == location)
        #expect(motion.encoded().withUnsafeBytes { MotionSample(decoding: $0, at: 0) } == motion)
        #expect(event.encoded().withUnsafeBytes { EventRecord(decoding: $0, at: 0) } == event)
    }
}

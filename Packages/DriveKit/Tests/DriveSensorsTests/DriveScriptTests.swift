import DriveDomain
import DriveSensors
import Testing

struct DriveScriptTests {
    /// The fixture every simulator run depends on must be physically consistent: lateral g must agree with how
    /// fast the GPS course turns, limits must hold, and the scripted stop and tunnel must exist.
    @Test func akagiIsPhysicallyConsistent() {
        let script = DriveScript.akagi
        #expect(script.duration > 20 * 60 && script.duration < 60 * 60)
        #expect(script.length > 20_000)

        var sawStop = false, sawTunnel = false
        var maxLateral = 0.0
        var t = 1.0
        while t < script.duration - 1 {
            let a = script.state(at: t), b = script.state(at: t + 1)
            maxLateral = max(maxLateral, abs(a.lateralAcceleration))
            if a.speed < 0.05, t > 10 { sawStop = true }
            if a.inTunnel { sawTunnel = true }
            if a.speed > 8, b.speed > 8 {
                // Course turns clockwise when yaw rate (CCW) is negative.
                let courseRate = Units.headingDelta(from: a.course, to: b.course) * .pi / 180
                #expect(abs(courseRate + (a.yawRate + b.yawRate) / 2) < 0.1, "t=\(t)")
            }
            t += 1
        }
        #expect(maxLateral <= 0.36 * Units.g)
        #expect(maxLateral > 0.2 * Units.g)
        #expect(sawStop)
        #expect(sawTunnel)
        // Parked after the end: no lingering braking.
        let parked = script.state(at: script.duration + 600)
        #expect(parked.speed == 0 && parked.longitudinalAcceleration == 0 && parked.yawRate == 0)
    }

    @Test func portraitMountReportsGravityDownScreenY() throws {
        var rng = SplitMix64(seed: 0)
        let synth = MotionSynthesizer(noise: 0)
        let event = synth.event(
            mode: .deviceMotion(hz: 50), timestamp: 0,
            dynamics: .init(longitudinal: Units.g * 0.3, lateral: Units.g * 0.2, yawRate: 0.1, yaw: 0), rng: &rng
        )
        guard case .deviceMotion(let sample) = event else { Issue.record("expected device motion"); return }
        #expect(sample.gravity == Vector3(x: 0, y: -1, z: 0))
        // Forward acceleration pushes into the screen's -z; a left turn is the screen's -x.
        #expect(abs(sample.userAcceleration.z + 0.3) < 1e-5)
        #expect(abs(sample.userAcceleration.x + 0.2) < 1e-5)
        // Round trip through the mount recovers the vehicle frame.
        let vehicle = MotionSynthesizer.portraitDashMount.apply(sample.userAcceleration)
        #expect(abs(vehicle.x - 0.3) < 1e-5 && abs(vehicle.y - 0.2) < 1e-5)
    }
}

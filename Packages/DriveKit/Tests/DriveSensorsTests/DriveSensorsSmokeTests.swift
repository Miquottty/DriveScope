import DriveSensors
import Testing

struct DriveSensorsSmokeTests {
    @Test func moduleLinks() {
        _ = DriveSensorsModule.self
    }
}

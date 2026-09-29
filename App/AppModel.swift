import AppIntents
import DriveDomain
import DriveRecording
import DriveSensors
import DriveStorage
import Foundation
import Network
import SwiftData
import UIKit

/// App-wide objects, created once at launch and injected through the environment.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let store: SessionStore
    let recorder: RecordingController
    let filesRoot: URL
    let sensorEnvironment: SensorEnvironment
    private let liveActivity: LiveActivityController
    private let notifications: RecordingNotifications
    private let deviceEvents: DeviceEventMonitor
    let battery: BatteryMonitor
    let finalizer: SessionFinalizer
    private let network = NWPathMonitor()

    init() {
        sensorEnvironment = SensorEnvironment.current()
        do {
            container = try SessionStore.makeContainer(inMemory: sensorEnvironment.isUITest)
            filesRoot = try SessionFiles.defaultRoot()
        } catch {
            fatalError("Cannot open the session store: \(error)")
        }
        store = SessionStore(context: container.mainContext)
        let device = UIDevice.current
        let environment = AppEnvironment(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            deviceModel: Self.hardwareModel(),
            osVersion: "\(device.systemName) \(device.systemVersion)"
        )
        // Re-read at every START so Settings changes (location backend) apply to the next session.
        let recorder = RecordingController(store: store, filesRoot: filesRoot, environment: environment) {
            SensorEnvironment.current().makeSuite()
        }
        recorder.prepareForStart = { recorder in
            #if DEBUG
            let fast = UserDefaults.standard.bool(forKey: "debugFastWatchdog")
            recorder.watchdogPolicy = fast ? RecordingWatchdog.Policy().accelerated(by: 10) : RecordingWatchdog.Policy()
            #endif
        }
        self.recorder = recorder
        // Live Activity MARK / STOP intents run in this process and reach the recorder through @Dependency.
        AppDependencyManager.shared.add(dependency: recorder)
        liveActivity = LiveActivityController(recorder: recorder)
        recorder.addObserver(liveActivity)
        notifications = RecordingNotifications(recorder: recorder)
        recorder.addObserver(notifications)
        deviceEvents = DeviceEventMonitor(recorder: recorder)
        recorder.addObserver(deviceEvents)
        let battery = BatteryMonitor(recorder: recorder)
        self.battery = battery
        recorder.addObserver(battery)
        recorder.willStop = { await battery.snapshot() }

        // Places + automatic title after STOP / recovery (PLAN §8), in the in-app language.
        let finalizer = SessionFinalizer(
            store: store, filesRoot: filesRoot,
            locale: { AppLanguage().locale }, loopWord: { AppLanguage().string("Loop") }
        )
        self.finalizer = finalizer
        recorder.onFinished = { session in
            session.geocodePending = true
            await finalizer.finalize(session)
        }
        // Offline at STOP → retry when the network returns (and once at launch).
        network.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await finalizer.retryPending() }
        }
        network.start(queue: DispatchQueue(label: "DriveScope.network"))
    }

    private static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        #else
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #endif
    }
}

/// Chooses where sensor data comes from:
/// - `-DriveSim <name> [-DriveSimSpeed <rate>]` launch arguments → a scripted drive (simulator, UI tests, screenshots)
/// - simulator → Core Location (`simctl location` routes) with motion / barometer derived from GPS
/// - device → Core Location + Core Motion
struct SensorEnvironment {
    enum Source: Equatable {
        case script(name: String, rate: Double)
        case simulatorRoute
        case device
    }

    enum LocationBackend: String {
        case locationManager
        case liveUpdates
    }

    var source: Source
    var locationBackend: LocationBackend
    var isUITest: Bool

    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> SensorEnvironment {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let backend = value(after: "-LocationBackend").flatMap(LocationBackend.init(rawValue:))
            ?? LocationBackend(rawValue: UserDefaults.standard.string(forKey: "locationBackend") ?? "") ?? .locationManager
        let isUITest = arguments.contains("-UITest")
        if let name = value(after: "-DriveSim"), DriveScript.named(name) != nil {
            let rate = value(after: "-DriveSimSpeed").flatMap(Double.init) ?? 1
            return SensorEnvironment(source: .script(name: name, rate: rate), locationBackend: backend, isUITest: isUITest)
        }
        #if targetEnvironment(simulator)
        return SensorEnvironment(source: .simulatorRoute, locationBackend: backend, isUITest: isUITest)
        #else
        return SensorEnvironment(source: .device, locationBackend: backend, isUITest: isUITest)
        #endif
    }

    /// Scripted drives need no location permission.
    var needsLocationPermission: Bool {
        if case .script = source { return false }
        return true
    }

    func makeSuite() -> SensorSuite {
        switch source {
        case .script(let name, let rate):
            return ScriptPlayback.suite(script: DriveScript.named(name) ?? .akagi, rate: rate, label: "script:\(name)")
        case .simulatorRoute:
            let clock = SystemClock()
            return SensorSuite(
                clock: clock, location: makeLocationSource(), motion: LocationDerivedMotionSource(clock: clock),
                altimeter: LocationDerivedAltimeterSource(), label: "simulator-route"
            )
        case .device:
            return SensorSuite(
                clock: SystemClock(), location: makeLocationSource(), motion: CoreMotionSource(),
                altimeter: CoreAltimeterSource(), label: "device"
            )
        }
    }

    private func makeLocationSource() -> any LocationSource {
        switch locationBackend {
        case .locationManager: CLLocationManagerSource()
        case .liveUpdates: LiveUpdatesLocationSource()
        }
    }
}

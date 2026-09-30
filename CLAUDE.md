# DriveScope — working notes for Claude

iPhone drive-telemetry logger (GPS + Core Motion + barometer → replay / export). The design source of truth is
`docs/PLAN.md`; the visual source of truth is `design/mock/` (tokens in `design/mock/README.md`).

## Toolchain
- **Always use `scripts/xc.sh`** — it pins Xcode 27.2 beta (`/Applications/Xcode-beta.app`) via `DEVELOPER_DIR`.
  `xcode-select` may point at the same Xcode on some hosts but isn't guaranteed across machines, so never call bare
  `xcodebuild` / `swift` without the wrapper.
- `scripts/xc.sh test` — DriveKit package tests on macOS (fast; run this first)
- `scripts/xc.sh build` — simulator build (iPhone 18 Pro, iOS 27.2); prints the `.app` path
- `scripts/xc.sh test-ios` / `test-ui` — UI tests on the simulator
- `scripts/xc.sh run [-DriveSim akagi …]` — build, install, launch on the simulator
- `scripts/xc.sh build-watch` / `run-pair` — watch app alone / app + watch app on a paired simulator
- `scripts/xc.sh build-device` — compile for the iphoneos SDK (device-only code paths)
- Launch flags: `-UITest` (isolated store/files), `-SeedSession <s>` (DEBUG demo session), `-appLanguage ja|en`; see docs/TESTING.md
- The project file is `DriveScope.xcodeproj/project.pbxproj` with **filesystem-synchronized groups**: adding a
  `.swift` file under `App/`, `Features/`, `Resources/`, `Shared/`, `LiveActivity/`, `Watch/`, `UITests/` needs no project edit.
  Do not edit the project file unless the task says so (only the lead does, via `xcodeproj` CLI in the pinned Xcode).

## Layout
| Path | Target | Notes |
|---|---|---|
| `App/` | DriveScope | App entry, root views, app-wide state (`AppLanguage`, `Theme`) |
| `Features/<Screen>/` | DriveScope | One folder per screen (Home, Recording, Sessions, SessionDetail, Replay, Quality, Settings, Recovery) |
| `Resources/` | DriveScope | `Localizable.xcstrings`, `InfoPlist.xcstrings`, `Assets.xcassets` |
| `Shared/` | DriveScope + DriveScopeWidgets | `DriveActivityAttributes`, Live Activity intents |
| `LiveActivity/` | DriveScopeWidgets | Widget extension (Live Activity UI) |
| `Watch/` | DriveScopeWatch | watchOS companion app (embedded in the app; links no packages, own String Catalog / theme copy) |
| `Packages/DriveKit/` | SwiftPM | `DriveDomain`, `DriveSensors`, `DriveStorage`, `DriveRecording`, `DriveReplay`, `DriveExport` |
| `Config/` | — | Partial Info.plists merged with generated keys |

## Conventions
- Swift 6 language mode. App target: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + approachable concurrency.
  DriveKit: nonisolated by default; sensor callbacks never hop to the MainActor; HUD updates are throttled to 10 Hz.
- DriveKit must compile on macOS: wrap iOS-only APIs (CMMotionManager, CMAltimeter, UIDevice, ActivityKit) in
  `#if os(iOS)` and keep protocol + Fake / Simulated implementations platform-neutral.
- Raw sensor data is stored untouched in device coordinates (PLAN §18). Smoothing / calibration only in derived data.
- UI: dark single theme; use `Theme` colors, never literal colors. Numbers use `.monospacedDigit()` (SF Mono look).
  HUD labels (ALT / COURSE / DIST / LAT G) and the START / MARK / SYNC / STOP button titles stay English in both
  languages; everything else (including their accessibility labels) is localized.
- Strings: String Catalog (`Localizable.xcstrings`), development language `en`, plus `ja`. Every user-facing string
  added must have both en and ja entries. Non-View code resolves strings via `AppLanguage` (see PLAN §13).
  Put `.relocalizing(appLanguage)` on every `NavigationStack` (UIKit nav titles otherwise keep the old language).
- Comments: sparse, explain *why*. Match the surrounding style.

## Tests (keep the suite small)
- Swift Testing (`import Testing`) in `Packages/DriveKit/Tests/*`. Budget: ~50 unit tests total for v1, 2 UI tests.
- Test behavior that would silently corrupt data or state: binary I/O and recovery, state machines, math
  (calibration, interpolation, statistics), exporters (small golden files). No tests for trivial getters or views.
- Prefer one well-chosen scenario over parameterized sweeps.

## Git
- Branch per sprint: `feature/sN-<name>`; PR to `main`, squash-merged. GitHub Actions are only added at the end (S7).
- Don't commit `.build/`, DerivedData, or `xcuserdata/`.

import DriveDomain
import DriveRecording
import DriveReplay
import DriveStorage
import SwiftUI

/// Duration and distance recomputed from the files of an unfinished session.
nonisolated struct RecoveryFigures: Sendable {
    var duration: TimeInterval
    var distance: Double
}

/// Crash Recovery Sheet (mock 7).
struct RecoverySheet: View {
    let candidate: RecoveryCandidate
    let onRecovered: (UUID) -> Void
    let onDiscarded: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(RecordingController.self) private var recorder
    @Environment(AppLanguage.self) private var appLanguage
    /// iPad: a centered form-sized card with the iPad type scale (set by `recoveryPrompt`).
    @Environment(\.iPadSheet) private var iPadSheet
    @State private var figures: RecoveryFigures?
    @State private var isWorking = false
    @State private var confirmingDiscard = false
    @State private var failure: String?

    var body: some View {
        if iPadSheet {
            iPadCard
        } else {
            phoneCard
        }
    }

    private var iPadCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Previous recording didn't finish")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(verbatim: detail)
                        .font(.hudNumber(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text(verbatim: failure)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.rec)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                recoverButton
                discardButton
            }
            if canResume {
                resumeButton
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .presentationBackground(Theme.surface)
        .interactiveDismissDisabled(isWorking)
        .task(id: candidate.id) {
            figures = await Self.figures(for: SessionFiles(root: model.filesRoot, sessionID: candidate.id))
        }
    }

    private var phoneCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Previous recording didn't finish")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(verbatim: detail)
                        .font(.hudNumber(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if let failure {
                Text(verbatim: failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.rec)
            }
            HStack(spacing: 10) {
                recoverButton
                discardButton
            }
            if canResume {
                resumeButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .presentationDetents([.height(canResume ? 214 : 176)])
        .presentationBackground(Theme.background)
        .interactiveDismissDisabled(isWorking)
        .task(id: candidate.id) {
            figures = await Self.figures(for: SessionFiles(root: model.filesRoot, sessionID: candidate.id))
        }
    }

    /// Continuing into the same files only makes sense shortly after the interruption (e.g. an accidental force
    /// quit mid-drive) and when the uptime clock survived (no reboot) — PLAN §9.3.
    private var canResume: Bool {
        guard let figures, recorder.canResume(candidate.session) else { return false }
        return RecordingController.resumeDecision(
            startUptime: candidate.session.startUptime, nowUptime: ProcessInfo.processInfo.systemUptime,
            startedAt: candidate.session.startedAt, lastElapsed: figures.duration, now: Date()
        )
    }

    private var resumeButton: some View {
        Button {
            Task {
                isWorking = true
                await recorder.resume(candidate.session)
                isWorking = false
            }
        } label: {
            Label("Resume recording", systemImage: "record.circle")
                .font(.system(size: iPadSheet ? 16 : 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: iPadSheet ? IPadMetrics.minTouch : 28)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityIdentifier("resumeButton")
    }

    private var recoverButton: some View {
        Button {
            Task { await recover() }
        } label: {
            ZStack {
                Text("Recover session").opacity(isWorking ? 0 : 1)
                if isWorking { ProgressView().tint(Theme.background) }
            }
            .font(.system(size: iPadSheet ? 16 : 14, weight: .semibold))
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: iPadSheet ? IPadMetrics.minTouch : 44)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityIdentifier("recoverButton")
    }

    private var discardButton: some View {
        Button {
            confirmingDiscard = true
        } label: {
            Text("Discard")
                .font(.system(size: iPadSheet ? 16 : 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: iPadSheet ? IPadMetrics.minTouch : 44)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.dividerStrong, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityIdentifier("discardButton")
        // Attached to the button so the dialog anchors there rather than to the whole sheet.
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                recorder.discard(candidate.session)
                onDiscarded()
            }
        } message: {
            Text("The recorded data is removed from this device.")
        }
    }

    /// "Sep 25 19:05 · 2:14:50 recovered · 188.3 km"; just the date if the files could not be read.
    private var detail: String {
        guard let figures else { return candidate.dateText }
        let format = SessionFormat(language: appLanguage)
        return [
            candidate.dateText,
            appLanguage.string("\(format.duration(figures.duration)) recovered"),
            format.distance(meters: figures.distance).text,
        ].joined(separator: " · ")
    }

    private func recover() async {
        isWorking = true
        defer { isWorking = false }
        failure = nil
        await recorder.recover(candidate.session)
        if candidate.session.state == .recovered {
            onRecovered(candidate.id)
        } else {
            failure = recorder.lastError
        }
    }

    /// A multi-hour log has hundreds of thousands of motion samples; read them off the main actor.
    @concurrent nonisolated private static func figures(for files: SessionFiles) async -> RecoveryFigures? {
        guard let manifest = try? files.readManifest(),
              let (statistics, duration) = try? SessionStatistics.compute(files: files, manifest: manifest)
        else { return nil }
        return RecoveryFigures(duration: duration, distance: statistics.distance)
    }
}

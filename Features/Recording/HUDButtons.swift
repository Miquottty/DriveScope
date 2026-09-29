import SwiftUI

/// MARK / SYNC: outlined dark buttons (mock: 64 pt portrait, 56 pt landscape, radius 14, 1.5 pt border).
/// After the action completes the button flashes amber with a checkmark so the driver gets confirmation
/// in peripheral vision, plus a haptic.
struct HUDActionButton: View {
    var title: String
    var systemImage: String
    var height: CGFloat
    var isEnabled = true
    var action: () async -> Void

    @State private var confirmations = 0
    @State private var isConfirming = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            Task {
                await action()
                confirm()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isConfirming ? "checkmark" : systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 18, height: 18)
                Text(verbatim: title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(1.2)
            }
            .foregroundStyle(isConfirming ? Theme.accent : Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(isConfirming ? Theme.accent.opacity(0.14) : HUDButtonStyle.fill,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isConfirming ? Theme.accent : Theme.dividerStrong, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(HUDButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .sensoryFeedback(.impact(weight: .medium), trigger: confirmations)
    }

    private func confirm() {
        confirmations += 1
        withAnimation(.easeOut(duration: 0.12)) { isConfirming = true }
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { isConfirming = false }
        }
    }
}

/// Press feedback without the system highlight tint.
struct HUDButtonStyle: ButtonStyle {
    /// Mock `#0F1215`: `Theme.surface` at 75 % over the true-black HUD gives the same color without a new token.
    static let fill = Theme.surface.opacity(0.75)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// STOP needs a deliberate hold (0.8 s) so a bump on the mount can't end a session. A lighter fill sweeps
/// across while holding; letting go early shows a "hold" hint instead of stopping.
struct StopButton: View {
    static let holdDuration: TimeInterval = 0.8

    var height: CGFloat
    var cornerRadius: CGFloat
    var fontSize: CGFloat
    var squareSize: CGFloat
    var isSaving: Bool
    var action: () async -> Void

    @State private var progress: CGFloat = 0
    @State private var pressStarted: Date?
    @State private var showsHint = false
    @State private var hintTask: Task<Void, Never>?
    @State private var holdStarts = 0
    @State private var stops = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        ZStack {
            shape.fill(Theme.rec)
            GeometryReader { proxy in
                Rectangle()
                    .fill(Theme.textPrimary.opacity(0.22))
                    .frame(width: proxy.size.width * progress)
            }
            .clipShape(shape)
            label
        }
        .frame(height: height)
        .contentShape(shape)
        .opacity(isSaving ? 0.6 : 1)
        .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 40) {
            stop()
        } onPressingChanged: { pressing in
            pressingChanged(pressing)
        }
        .allowsHitTesting(!isSaving)
        .sensoryFeedback(.impact(weight: .light), trigger: holdStarts)
        .sensoryFeedback(.impact(weight: .heavy), trigger: stops)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: isSaving ? "Saving…" : "STOP"))
        .accessibilityHint(Text("Hold to stop"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { stop() }
    }

    @ViewBuilder private var label: some View {
        HStack(spacing: 10) {
            if isSaving {
                ProgressView()
                    .tint(Theme.textPrimary)
                    .controlSize(.small)
                Text(verbatim: "Saving…")
                    .font(.system(size: fontSize - 2, weight: .semibold))
            } else if showsHint {
                Text("Hold to stop")
                    .textCase(.uppercase)
                    .font(.system(size: fontSize - 3, weight: .semibold))
                    .tracking(fontSize * 0.08)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.textPrimary)
                    .frame(width: squareSize, height: squareSize)
                Text(verbatim: "STOP")
                    .font(.system(size: fontSize, weight: .semibold))
                    .tracking(fontSize * 0.12)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func pressingChanged(_ pressing: Bool) {
        if pressing {
            pressStarted = .now
            holdStarts += 1
            hideHint()
            withAnimation(.linear(duration: Self.holdDuration)) { progress = 1 }
        } else {
            // The order of `perform` vs. `onPressingChanged(false)` isn't specified, so decide by elapsed time.
            let held = pressStarted.map { Date.now.timeIntervalSince($0) } ?? 0
            pressStarted = nil
            withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            if held < Self.holdDuration { flashHint() }
        }
    }

    private func stop() {
        guard !isSaving else { return }
        stops += 1
        Task { await action() }
    }

    private func flashHint() {
        withAnimation(.easeOut(duration: 0.15)) { showsHint = true }
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            hideHint()
        }
    }

    private func hideHint() {
        hintTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) { showsHint = false }
    }
}

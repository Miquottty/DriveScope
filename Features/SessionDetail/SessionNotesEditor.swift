import DriveDomain
import DriveStorage
import SwiftUI

/// Free-form notes, saved shortly after typing stops and when the field loses focus or the screen goes away.
/// Holds the session id, not the model: after a delete the pending save must not touch the invalidated object.
struct SessionNotesEditor: View {
    let sessionID: UUID
    /// iPad type scale (16 pt text, 13 pt caps label, no muted text).
    let large: Bool

    @Environment(AppModel.self) private var model
    @State private var draft: String
    @FocusState private var focused: Bool

    init(session: DriveSession, large: Bool = false) {
        sessionID = session.id
        self.large = large
        _draft = State(initialValue: session.notes ?? "")
    }

    var body: some View {
        editor
            .task(id: draft) {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                commit()
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onDisappear { commit() }
            .toolbar {
                // Only while this field is editing: other keyboards on the screen (the rename alert) must not get it.
                if focused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focused = false }
                    }
                }
            }
    }

    @ViewBuilder private var editor: some View {
        if large {
            VStack(alignment: .leading, spacing: 10) {
                Text("Notes").iPadLabel()
                field(prompt: Theme.textSecondary)
                    .lineLimit(3...10)
                    .font(.system(size: 16))
            }
            .iPadCard(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                    .font(.system(size: 10))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.textSecondary)
                field(prompt: Theme.textMuted)
                    .lineLimit(2...8)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func field(prompt: Color) -> some View {
        TextField(text: $draft, prompt: Text("Add notes").foregroundStyle(prompt), axis: .vertical) {
            Text("Notes")
        }
        .foregroundStyle(Theme.textPrimary)
        .focused($focused)
        .accessibilityIdentifier("notesField")
    }

    private func commit() {
        guard let session = model.store.session(id: sessionID) else { return }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft
        guard value != session.notes else { return }
        session.notes = value
        try? model.store.save()
    }
}

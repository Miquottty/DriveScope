import DriveDomain
import DriveStorage
import SwiftUI

/// Free-form notes, saved shortly after typing stops and when the field loses focus or the screen goes away.
/// Holds the session id, not the model: after a delete the pending save must not touch the invalidated object.
struct SessionNotesEditor: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model
    @State private var draft: String
    @FocusState private var focused: Bool

    init(session: DriveSession) {
        sessionID = session.id
        _draft = State(initialValue: session.notes ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.system(size: 10))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
            TextField(text: $draft, prompt: Text("Add notes").foregroundStyle(Theme.textMuted), axis: .vertical) {
                Text("Notes")
            }
            .lineLimit(2...8)
            .font(.system(size: 14))
            .foregroundStyle(Theme.textPrimary)
            .focused($focused)
            .accessibilityIdentifier("notesField")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
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

    private func commit() {
        guard let session = model.store.session(id: sessionID) else { return }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft
        guard value != session.notes else { return }
        session.notes = value
        try? model.store.save()
    }
}

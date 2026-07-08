import SwiftUI

/// The small pencil affordance in a detail header that opens the note editor - the only edit entry point.
/// Tinted when a note already exists. Shared by both detail screens so they stay identical.
struct NoteButton: View {
    let hasNote: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: hasNote ? "note.text" : "note.text.badge.plus")
                .font(.title3)
                .foregroundStyle(hasNote ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasNote ? "Edit note" : "Add note")
    }
}

/// The read-only "Note" row rendered under a detail header, only when a note exists.
struct NoteRow: View {
    let note: String
    init(_ note: String) { self.note = note }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Note").font(.caption).foregroundStyle(.secondary)
            Text(note)
        }
    }
}

/// A compact editor for the per-user free-text Note shared by the transaction and expense detail screens.
/// Seeds from the current note; `onSave` receives the edited text (empty string clears the note). Presented
/// from the small pencil icon in each detail header.
struct NoteEditorSheet: View {
    let initial: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @FocusState private var focused: Bool

    init(initial: String, onSave: @escaping (String) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("e.g. Duolingo subscription", text: $draft, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focused)
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

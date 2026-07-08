import SwiftUI

/// A top-right "Save" button plus an unsaved-changes guard for a pushed settings screen. While `dirty`, the
/// native back button is replaced by one that confirms before discarding (and offers Save & Close); when
/// clean, the native back button and swipe-back are left untouched. `save` returns true on success, so
/// Save & Close only dismisses when the save actually took.
struct UnsavedChangesGuard: ViewModifier {
    let dirty: Bool
    var saving: Bool = false
    /// When false, only the confirm-on-leave back button is shown (no top-right Save) - for screens that save
    /// per-row and just need the leave guard; the `save` closure then acts as "save all" for Save & Close.
    var showsSaveButton: Bool = true
    let save: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var confirmLeave = false

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(dirty)
            .toolbar {
                if dirty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { confirmLeave = true } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                    }
                }
                if showsSaveButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") { Task { _ = await save() } }
                            .fontWeight(.semibold)
                            .disabled(!dirty || saving)
                    }
                }
            }
            .confirmationDialog("You have unsaved changes.", isPresented: $confirmLeave,
                                titleVisibility: .visible) {
                Button("Save & Close") { Task { if await save() { dismiss() } } }
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Save your changes before leaving?")
            }
    }
}

extension View {
    /// See `UnsavedChangesGuard`. `save` should perform the save and return whether it succeeded.
    func unsavedChangesGuard(dirty: Bool, saving: Bool = false, showsSaveButton: Bool = true,
                             save: @escaping () async -> Bool) -> some View {
        modifier(UnsavedChangesGuard(dirty: dirty, saving: saving,
                                     showsSaveButton: showsSaveButton, save: save))
    }
}

import SwiftUI

/// A write action awaiting confirmation, used when "Confirm before every write" is on.
struct WriteRequest: Identifiable {
    let id = UUID()
    let title: String
    let perform: () -> Void
}

extension View {
    /// Presents a confirm dialog for a pending guarded write (the panes set `request`
    /// via their `requestWrite` helper when the global confirm-writes setting is on).
    func writeConfirm(_ request: Binding<WriteRequest?>) -> some View {
        alert("Confirm write", isPresented: Binding(
            get: { request.wrappedValue != nil },
            set: { if !$0 { request.wrappedValue = nil } }
        ), presenting: request.wrappedValue) { req in
            Button("Confirm") { req.perform(); request.wrappedValue = nil }
            Button("Cancel", role: .cancel) { request.wrappedValue = nil }
        } message: { req in
            Text(req.title)
        }
    }
}

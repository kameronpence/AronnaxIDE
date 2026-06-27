import SwiftUI

/// The "Chat" pane: the subscription web chats (claude.ai and ChatGPT) as
/// logged-in web views, switchable via sub-tabs. The CLI coding agents live
/// separately in the "Coding" pane.
///
/// Both web views are kept alive (shown/hidden, not recreated) so switching tabs
/// is instant and never drops a login or scroll position.
struct WebChatPane: View {
    @State private var selected: WebChat = .claude

    var body: some View {
        VStack(spacing: 0) {
            Picker("Chat", selection: $selected) {
                ForEach(WebChat.allCases) { chat in
                    Text(chat.title).tag(chat)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            ZStack {
                ForEach(WebChat.allCases) { chat in
                    WebChatView(chat: chat)
                        .opacity(chat == selected ? 1 : 0)
                        .allowsHitTesting(chat == selected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

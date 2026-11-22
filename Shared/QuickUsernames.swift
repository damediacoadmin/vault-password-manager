import SwiftUI

/// Settings block: your own emails and usernames, offered as one-tap chips when creating logins.
struct QuickUsernamesPanel: View {
    @EnvironmentObject var store: VaultStore
    @State private var newEntry = ""

    var body: some View {
        let list = store.payload.quickUsernames ?? []
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("My emails and usernames")
            Panel {
                VStack(spacing: 0) {
                    ForEach(list, id: \.self) { u in
                        HStack {
                            Text(u).font(.mono(15)).foregroundStyle(Ink.text).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { store.setQuickUsernames(list.filter { $0 != u }) } label: {
                                Image(systemName: "minus.circle").foregroundStyle(Ink.red).frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(u)")
                        }
                        .padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 48)
                        Hairline()
                    }
                    HStack(spacing: 8) {
                        TextField("", text: $newEntry, prompt: Text("Add an email or username").foregroundStyle(Ink.muted))
                            .textFieldStyle(.plain).font(.mono(15)).foregroundStyle(Ink.text).autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never).keyboardType(.emailAddress)
                            #endif
                            .onSubmit(add)
                        Button("Add", action: add).font(.plex(15, .semibold)).foregroundStyle(Ink.amber)
                            .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44).disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 52)
                }
            }
            Text("These show first as tap-to-fill buttons when you create a login. They sync to your other devices.")
                .font(.plex(12)).foregroundStyle(Ink.muted)
        }
    }

    private func add() {
        let v = newEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        var list = store.payload.quickUsernames ?? []
        if !list.contains(v) { list.append(v) }
        store.setQuickUsernames(list)
        newEntry = ""
    }
}

/// One-tap username chips under a username field.
struct UsernameChips: View {
    @EnvironmentObject var store: VaultStore
    @Binding var username: String
    var body: some View {
        let chips = store.usernameSuggestions()
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { u in
                        Button { username = u } label: {
                            Text(u).font(.mono(13)).lineLimit(1)
                                .padding(.horizontal, 12).frame(height: 34)
                                .foregroundStyle(username == u ? Ink.bg : Ink.text)
                                .background(username == u ? Ink.amber : Ink.panel, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(username == u ? Ink.amber : Ink.line))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
    }
}

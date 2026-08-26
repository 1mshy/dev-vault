import SwiftUI

struct DocumentEditor: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var themes: ThemeManager
    @Binding var document: VaultDocument

    private enum Mode: String, CaseIterable {
        case edit = "Edit"
        case preview = "Preview"
    }

    @State private var mode: Mode = .edit
    @FocusState private var titleFocused: Bool

    private var theme: Theme { themes.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Untitled", text: $document.title)
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.resolvedTextPrimary)
                    .focused($titleFocused)
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Text(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if mode == .edit {
                LiveMarkdownEditor(text: $document.content, theme: theme)
            } else {
                MarkdownPreview(text: document.content)
            }

            Divider()

            HStack {
                Text("Edited \(document.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                Spacer()
                Text("\(document.content.count) characters")
            }
            .font(.caption)
            .foregroundStyle(theme.resolvedTextSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .themedBackground(theme.contentBackground)
        .onAppear {
            // New documents are created with an empty title; put the cursor
            // straight in the title field so it can be named immediately.
            if document.title.isEmpty {
                DispatchQueue.main.async { titleFocused = true }
            }
        }
        .onChange(of: document.content) { _ in
            document.updatedAt = Date()
            store.scheduleSave()
        }
        .onChange(of: document.title) { _ in
            document.updatedAt = Date()
            store.scheduleSave()
        }
    }
}

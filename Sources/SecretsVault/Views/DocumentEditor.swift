import SwiftUI

struct DocumentEditor: View {
    @EnvironmentObject var store: VaultStore
    @Binding var document: VaultDocument

    private enum Mode: String, CaseIterable {
        case edit = "Edit"
        case preview = "Preview"
    }

    @State private var mode: Mode = .edit

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Title", text: $document.title)
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
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
                TextEditor(text: $document.content)
                    .font(.system(size: 13.5, design: .monospaced))
                    .autocorrectionDisabled(true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
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
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
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

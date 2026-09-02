import SwiftUI
import SecretsVaultCore

struct MainView: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var themes: ThemeManager
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(searchText: $searchText)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
                .themedToolbarBackground(themes.current.sidebarBackground ?? themes.current.windowBackground)
        } detail: {
            DetailView()
                .themedToolbarBackground(themes.current.windowBackground)
        }
        .searchable(text: $searchText, prompt: "Search vault")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if #available(macOS 14.0, *) {
                    // showSettingsWindow: no longer works on macOS 14+;
                    // SettingsLink is the supported way to open Settings.
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Settings (\u{2318},)")
                } else {
                    Button {
                        SettingsWindow.open()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Settings (\u{2318},)")
                }
                Button {
                    store.lock()
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
                .help("Lock the vault (⌘L)")
            }
        }
        .onChange(of: store.selectedDocumentID) { _ in
            store.touchActivity()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var themes: ThemeManager
    @Binding var searchText: String

    @State private var collapsed: Set<UUID> = []
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: VaultFolder?
    @State private var renameText = ""
    @State private var deleteFolderTarget: VaultFolder?
    @State private var purgeDocTarget: VaultDocument?
    @State private var showEmptyTrashConfirm = false

    private var theme: Theme { themes.current }

    private var sortedFolders: [VaultFolder] {
        store.data.folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List(selection: $store.selectedDocumentID) {
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Section("Results") {
                    let results = store.searchResults(searchText)
                    ForEach(results) { doc in
                        documentRow(doc)
                    }
                    if results.isEmpty {
                        Text("No matches").font(.caption).foregroundStyle(theme.resolvedTextTertiary)
                    }
                }
            } else {
                Section("Documents") {
                    let rootDocs = store.documents(in: nil)
                    ForEach(rootDocs) { doc in
                        documentRow(doc)
                    }
                    if rootDocs.isEmpty && store.data.folders.isEmpty {
                        Text("No documents yet").font(.caption).foregroundStyle(theme.resolvedTextTertiary)
                    }
                }
                Section("Folders") {
                    ForEach(sortedFolders) { folder in
                        DisclosureGroup(isExpanded: expansionBinding(folder.id)) {
                            let docs = store.documents(in: folder.id)
                            ForEach(docs) { doc in
                                documentRow(doc)
                            }
                            if docs.isEmpty {
                                Text("Empty").font(.caption).foregroundStyle(theme.resolvedTextTertiary)
                            }
                        } label: {
                            Label(folder.name, systemImage: "folder")
                                .contextMenu {
                                    Button("New Document") { store.addDocument(in: folder.id) }
                                    Button("Rename…") {
                                        renameText = folder.name
                                        renameTarget = folder
                                    }
                                    Divider()
                                    Button("Delete Folder…", role: .destructive) {
                                        deleteFolderTarget = folder
                                    }
                                }
                        }
                    }
                }
                if !store.deletedDocuments.isEmpty {
                    Section("Recently Deleted") {
                        ForEach(store.deletedDocuments) { doc in
                            deletedDocumentRow(doc)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .themedScrollBackground(theme.sidebarBackground)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .help("New folder")
                Button {
                    store.addDocument(in: nil)
                } label: {
                    Label("New Document", systemImage: "square.and.pencil")
                }
                .help("New document (⌘N)")
            }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { store.addFolder(named: newFolderName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder", isPresented: presentBinding($renameTarget)) {
            TextField("Folder name", text: $renameText)
            Button("Rename") {
                if let f = renameTarget { store.renameFolder(f.id, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Delete Folder?", isPresented: presentBinding($deleteFolderTarget)) {
            Button("Delete", role: .destructive) {
                if let f = deleteFolderTarget { store.deleteFolder(f.id) }
                deleteFolderTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteFolderTarget = nil }
        } message: {
            Text("Documents inside \u{201C}\(deleteFolderTarget?.name ?? "")\u{201D} will be moved to Documents.")
        }
        .alert("Delete Permanently?", isPresented: presentBinding($purgeDocTarget)) {
            Button("Delete Permanently", role: .destructive) {
                if let d = purgeDocTarget { store.purgeDocument(d.id) }
                purgeDocTarget = nil
            }
            Button("Cancel", role: .cancel) { purgeDocTarget = nil }
        } message: {
            Text("\u{201C}\(purgeDocTarget?.title ?? "")\u{201D} will be removed from the vault forever. This cannot be undone.")
        }
        .alert("Empty Recently Deleted?", isPresented: $showEmptyTrashConfirm) {
            Button("Delete All Permanently", role: .destructive) { store.emptyRecentlyDeleted() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(store.deletedDocuments.count) documents in Recently Deleted will be removed forever. This cannot be undone.")
        }
    }

    private func documentRow(_ doc: VaultDocument) -> some View {
        Label(doc.title.isEmpty ? "Untitled" : doc.title, systemImage: "doc.text")
            .tag(Optional(doc.id))
            .contextMenu {
                Menu("Move To") {
                    Button("Documents") { store.moveDocument(doc.id, to: nil) }
                    Divider()
                    ForEach(sortedFolders) { f in
                        Button(f.name) { store.moveDocument(doc.id, to: f.id) }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { store.deleteDocument(doc.id) }
            }
    }

    private func deletedDocumentRow(_ doc: VaultDocument) -> some View {
        Label(doc.title.isEmpty ? "Untitled" : doc.title, systemImage: "trash")
            .foregroundStyle(.secondary)
            .tag(Optional(doc.id))
            .contextMenu {
                Button("Restore") { store.restoreDocument(doc.id) }
                Divider()
                Button("Delete Permanently…", role: .destructive) { purgeDocTarget = doc }
                Button("Empty Recently Deleted…", role: .destructive) { showEmptyTrashConfirm = true }
            }
    }

    private func expansionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { expanded in
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
            }
        )
    }

    private func presentBinding<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
    }
}

struct DetailView: View {
    @EnvironmentObject var store: VaultStore

    var body: some View {
        if let selected = store.selectedDocumentID,
           let idx = store.data.documents.firstIndex(where: { $0.id == selected }) {
            if store.data.documents[idx].deletedAt != nil {
                DeletedDocumentView(document: store.data.documents[idx])
                    .id(selected)
            } else {
                DocumentEditor(document: $store.data.documents[idx])
                    .id(selected)
            }
        } else {
            EmptySelectionView()
        }
    }
}

struct EmptySelectionView: View {
    @EnvironmentObject var themes: ThemeManager

    private var theme: Theme { themes.current }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(theme.resolvedTextTertiary)
            Text("No Document Selected")
                .font(.title3)
                .foregroundStyle(theme.resolvedTextSecondary)
            Text("Select a document in the sidebar or press ⌘N to create one.")
                .font(.callout)
                .foregroundStyle(theme.resolvedTextTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground(theme.contentBackground)
    }
}

struct DeletedDocumentView: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var themes: ThemeManager
    let document: VaultDocument
    @State private var confirmPurge = false

    private var theme: Theme { themes.current }

    private var displayTitle: String {
        document.title.isEmpty ? "Untitled" : document.title
    }

    private var purgeDate: Date {
        (document.deletedAt ?? Date())
            .addingTimeInterval(Double(VaultStore.deletedRetentionDays) * 86_400)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(displayTitle)
                    .font(.title2.bold())
                    .foregroundStyle(theme.resolvedTextPrimary)
                    .lineLimit(1)
                Spacer()
                Button("Restore") { store.restoreDocument(document.id) }
                Button("Delete Permanently…", role: .destructive) { confirmPurge = true }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "trash")
                Text("In Recently Deleted — removed forever on \(purgeDate.formatted(date: .abbreviated, time: .omitted)). Restore to edit.")
            }
            .font(.callout)
            .foregroundStyle(theme.resolvedTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(theme.resolvedBanner)

            MarkdownPreview(text: document.content)
        }
        .themedBackground(theme.contentBackground)
        .alert("Delete Permanently?", isPresented: $confirmPurge) {
            Button("Delete Permanently", role: .destructive) { store.purgeDocument(document.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\u{201C}\(displayTitle)\u{201D} will be removed from the vault forever. This cannot be undone.")
        }
    }
}

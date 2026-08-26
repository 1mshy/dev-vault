import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: VaultStore
    @State private var searchText = ""
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            SidebarView(searchText: $searchText)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            DetailView()
        }
        .searchable(text: $searchText, prompt: "Search vault")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
                Button {
                    store.lock()
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
                .help("Lock the vault (⌘L)")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store)
        }
        .onChange(of: store.selectedDocumentID) { _ in
            store.touchActivity()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: VaultStore
    @Binding var searchText: String

    @State private var collapsed: Set<UUID> = []
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: VaultFolder?
    @State private var renameText = ""
    @State private var deleteFolderTarget: VaultFolder?
    @State private var deleteDocTarget: VaultDocument?

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
                        Text("No matches").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            } else {
                Section("Documents") {
                    let rootDocs = store.documents(in: nil)
                    ForEach(rootDocs) { doc in
                        documentRow(doc)
                    }
                    if rootDocs.isEmpty && store.data.folders.isEmpty {
                        Text("No documents yet").font(.caption).foregroundStyle(.tertiary)
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
                                Text("Empty").font(.caption).foregroundStyle(.tertiary)
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
            }
        }
        .listStyle(.sidebar)
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
        .alert("Delete Document?", isPresented: presentBinding($deleteDocTarget)) {
            Button("Delete", role: .destructive) {
                if let d = deleteDocTarget { store.deleteDocument(d.id) }
                deleteDocTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteDocTarget = nil }
        } message: {
            Text("\u{201C}\(deleteDocTarget?.title ?? "")\u{201D} will be permanently removed from the vault.")
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
                Button("Delete…", role: .destructive) { deleteDocTarget = doc }
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
            DocumentEditor(document: $store.data.documents[idx])
                .id(selected)
        } else {
            EmptySelectionView()
        }
    }
}

struct EmptySelectionView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Document Selected")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Select a document in the sidebar or press ⌘N to create one.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query private var feeds: [Feed]

    @State private var showOPMLImporter = false
    @State private var showOPMLExporter = false
    @State private var opmlExportContent = ""
    @State private var importError: String?
    @State private var importSuccessCount = 0
    @State private var showImportResult = false

    var body: some View {
        NavigationStack {
            Form {
                categoriesSection
                opmlSection
                aboutSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showOPMLImporter,
                allowedContentTypes: [.xml, UTType("public.opml") ?? .xml]
            ) { result in
                handleOPMLImport(result: result)
            }
            .fileExporter(
                isPresented: $showOPMLExporter,
                document: OPMLDocument(content: opmlExportContent),
                contentType: .xml,
                defaultFilename: "yomi-feeds.opml"
            ) { _ in }
            .alert("Import Complete", isPresented: $showImportResult) {
                Button("OK") {}
            } message: {
                if let err = importError {
                    Text(err)
                } else {
                    Text("Added \(importSuccessCount) feeds")
                }
            }
        }
    }

    private var categoriesSection: some View {
        Section {
            NavigationLink {
                CategoriesView()
            } label: {
                LabeledContent("Categories") {
                    Text("\(categories.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var opmlSection: some View {
        Section("OPML") {
            Button {
                opmlExportContent = OPMLManager.shared.exportOPML(feeds: feeds)
                showOPMLExporter = true
            } label: {
                Label("Export Feeds", systemImage: "square.and.arrow.up")
            }

            Button {
                showOPMLImporter = true
            } label: {
                Label("Import OPML", systemImage: "square.and.arrow.down")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                Text("About")
            }
        }
    }

    private func handleOPMLImport(result: Result<URL, Error>) {
        importError = nil
        importSuccessCount = 0

        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                let opmlFeeds = try OPMLManager.shared.importOPML(data: data)
                Task {
                    var added = 0
                    for opmlFeed in opmlFeeds {
                        if let _ = try? await FeedService.shared.addFeed(
                            url: opmlFeed.xmlURL,
                            category: opmlFeed.category,
                            context: context
                        ) { added += 1 }
                    }
                    await MainActor.run {
                        importSuccessCount = added
                        showImportResult = true
                    }
                }
            } catch {
                importError = error.localizedDescription
                showImportResult = true
            }
        case .failure(let error):
            importError = error.localizedDescription
            showImportResult = true
        }
    }
}

struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }
    var content: String

    init(content: String) { self.content = content }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        content = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(content.utf8))
    }
}

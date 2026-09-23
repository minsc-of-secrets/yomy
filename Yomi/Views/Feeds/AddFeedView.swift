import SwiftUI
import SwiftData

struct AddFeedView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var urlText = ""
    @State private var selectedCategory = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Feed URL") {
                    ZStack(alignment: .leading) {
                        if urlText.isEmpty {
                            Text(verbatim: "https://example.com/feed")
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $urlText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                CategoryPickerSection(selectedCategory: $selectedCategory)

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Add Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark") {
                        Task { await addFeed() }
                    }
                    .disabled(urlText.isEmpty || isLoading)
                }
            }
            .onAppear {
                guard selectedCategory.isEmpty else { return }
                if let general = categories.first(where: { $0.name == "General" }) {
                    selectedCategory = general.name
                } else if let first = categories.first {
                    selectedCategory = first.name
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func addFeed() async {
        isLoading = true
        errorMessage = nil
        do {
            let _ = try await FeedService.shared.addFeed(url: urlText, category: selectedCategory, context: context)
            dismiss()
        } catch {
            errorMessage = "Failed to fetch feed: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

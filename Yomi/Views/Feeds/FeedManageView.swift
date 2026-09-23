import SwiftUI
import SwiftData

struct FeedManageView: View {
    let feed: Feed
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategory: String

    init(feed: Feed) {
        self.feed = feed
        self._selectedCategory = State(initialValue: feed.category)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Feed Info") {
                    LabeledContent("Title", value: feed.title)
                    LabeledContent("URL") {
                        Text(feed.url)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                CategoryPickerSection(selectedCategory: $selectedCategory)
            }
            .navigationTitle("Edit Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        feed.category = selectedCategory
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

import SwiftUI
import SwiftData

struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var deleteError: String?

    var body: some View {
        List {
            ForEach(categories) { category in
                NavigationLink {
                    CategoryEditView(category: category)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: category.iconName)
                            .frame(width: 24)
                            .foregroundStyle(.primary)
                        Text(category.name)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .onDelete { indexSet in
                do {
                    try CategoryService().delete(indexSet.map { categories[$0] }, context: context)
                } catch {
                    deleteError = error.localizedDescription
                }
            }
        }
        .overlay {
            if categories.isEmpty {
                ContentUnavailableView(
                    "No Categories",
                    systemImage: "folder",
                    description: Text("Tap + to add a category")
                )
            }
        }
        .alert("Could Not Delete Category", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    CategoryEditView()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}
